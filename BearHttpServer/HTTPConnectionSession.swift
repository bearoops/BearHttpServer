//
//  HTTPConnectionSession.swift
//  BearHttpServer
//

import Foundation
import Network

final class HTTPConnectionSession: @unchecked Sendable {
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private static let headerSeparator: [UInt8] = [13, 10, 13, 10] // CRLF CRLF

    private let connection: NWConnection
    private let configuration: HTTPServerConfiguration
    private let handler: RequestHandler

    init(
        connection: NWConnection,
        configuration: HTTPServerConfiguration,
        handler: @escaping RequestHandler
    ) {
        self.connection = connection
        self.configuration = configuration
        self.handler = handler
    }

    func run() async {
        var buffer = Data()

        while true {
            switch Self.parseNextRequest(from: &buffer, configuration: configuration) {
            case .request(let request, let closeAfterResponse):
                let response = await handler(request)
                let shouldContinue = await send(
                    response,
                    close: closeAfterResponse,
                    includeBody: request.method != .head
                )
                if !shouldContinue {
                    return
                }

            case .error(let status, let message):
                await sendError(status: status, message: message)
                return

            case .needMore:
                do {
                    let (chunk, isComplete) = try await receive()
                    buffer.append(chunk)
                    if isComplete {
                        return
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func receive() async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
    }

    @discardableResult
    private func send(_ response: HTTPResponse, close: Bool, includeBody: Bool) async -> Bool {
        let status = response.status
        // 1xx, 204 and 304 must not carry a message body or Content-Length.
        // HEAD still reports the length a GET would have returned.
        let statusAllowsBody = !(100..<200).contains(status.code)
            && status.code != 204
            && status.code != 304
        let bodyForLength = statusAllowsBody ? response.body : Data()
        let bodyToSend = statusAllowsBody && includeBody ? response.body : Data()

        var payload = Data()
        let reasonPhrase = sanitizedHTTPField(status.reasonPhrase)
        payload.append(contentsOf: "HTTP/1.1 \(status.code) \(reasonPhrase)\r\n".utf8)

        var headers = response.headers
        headers["server"] = configuration.serverHeader
        headers["date"] = Self.currentHTTPDate()
        if statusAllowsBody {
            headers["content-length"] = String(bodyForLength.count)
        } else {
            headers["content-length"] = nil
        }
        headers["connection"] = close ? "close" : "keep-alive"
        if !bodyForLength.isEmpty && headers["content-type"] == nil {
            headers["content-type"] = "application/octet-stream"
        }

        // Serialize the header collection into wire format: one
        // "name: value\r\n" line per field, then a blank line to end the block.
        // Sorting the names keeps output deterministic, which makes the raw
        // response byte-for-byte predictable in tests.
        for (name, value) in headers.all.sorted(by: { $0.key < $1.key }) {
            // Defensive cleanup at the serialization boundary. HTTPHeaders
            // already sanitizes on insertion, but doing it again here means a
            // value can never escape into a new header line at this last step.
            let safeName = sanitizedHTTPField(name)
            // Ordinary headers contain a single value. Set-Cookie is special:
            // cookies cannot be folded into one comma-separated line, so
            // HTTPHeaders stores several of them as "a\r\nSet-Cookie: b".
            // Splitting on CRLF restores one wire line per cookie. Keeping
            // empty subsequences preserves the original line structure.
            for line in value.split(separator: "\r\n", omittingEmptySubsequences: false) {
                let safeLine = sanitizedHTTPField(String(line))
                payload.append(contentsOf: safeName.utf8)
                payload.append(contentsOf: [58, 32]) // ": "
                payload.append(contentsOf: safeLine.utf8)
                payload.append(contentsOf: [13, 10]) // CRLF
            }
        }
        // The empty CRLF line separates the header block from the body.
        payload.append(contentsOf: [13, 10])

        if !bodyToSend.isEmpty {
            payload.append(bodyToSend)
        }

        do {
            try await sendAll(payload)
            return !close
        } catch {
            return false
        }
    }

    private func sendAll(_ data: Data) async throws {
        guard !data.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func sendError(status: HTTPStatusCode, message: String) async {
        _ = await send(
            HTTPResponse.text(message, status: status),
            close: true,
            includeBody: true
        )
    }

    private static func currentHTTPDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }

    private enum ParseResult {
        case needMore
        case request(HTTPRequest, close: Bool)
        case error(HTTPStatusCode, String)
    }

    private static func parseNextRequest(
        from buffer: inout Data,
        configuration: HTTPServerConfiguration
    ) -> ParseResult {
        guard let headerEnd = findHeaderEnd(in: buffer) else {
            if buffer.count > configuration.maxHeaderBytes {
                return .error(.requestHeaderFieldsTooLarge, "Request headers are too large.")
            }
            return .needMore
        }

        if headerEnd > configuration.maxHeaderBytes {
            return .error(.requestHeaderFieldsTooLarge, "Request headers are too large.")
        }

        let bodyStart = headerEnd + headerSeparator.count
        guard let headerText = String(
            data: buffer.subdata(in: 0..<headerEnd),
            encoding: .utf8
        ) else {
            return .error(.badRequest, "Request headers are not valid UTF-8.")
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return .error(.badRequest, "Missing request line.")
        }

        let components = requestLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard components.count == 3 else {
            return .error(.badRequest, "Malformed request line.")
        }

        let method = HTTPMethod(rawValue: String(components[0]))
        let target = String(components[1])
        let version = HTTPVersion(rawValue: String(components[2]))

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                return .error(.badRequest, "Malformed request header.")
            }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .error(.badRequest, "Malformed request header name.")
            }
            headers.append(name, value: value)
        }

        if let transferEncoding = headers["transfer-encoding"],
           transferEncoding.lowercased().contains("chunked") {
            return .error(.notImplemented, "Chunked request bodies are not supported.")
        }

        var contentLength = 0
        if let rawContentLength = headers["content-length"] {
            let trimmed = rawContentLength.trimmingCharacters(in: .whitespaces)
            guard let value = Int(trimmed), value >= 0 else {
                return .error(.badRequest, "Invalid Content-Length.")
            }
            contentLength = value
        }

        guard contentLength <= configuration.maxBodyBytes else {
            return .error(.payloadTooLarge, "Request body is too large.")
        }
        guard contentLength <= Int.max - bodyStart else {
            return .error(.payloadTooLarge, "Request body is too large.")
        }

        let requestEnd = bodyStart + contentLength
        guard buffer.count >= requestEnd else {
            return .needMore
        }

        let body = Data(buffer.subdata(in: bodyStart..<requestEnd))
        buffer = Data(buffer.subdata(in: requestEnd..<buffer.count))

        let request = HTTPRequest(
            method: method,
            target: target,
            version: version,
            headers: headers,
            body: body
        )
        return .request(request, close: shouldClose(version: version, headers: headers))
    }

    private static func findHeaderEnd(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSeparator.count else { return nil }

        var index = 0
        while index <= bytes.count - headerSeparator.count {
            if bytes[index] == headerSeparator[0],
               bytes[index + 1] == headerSeparator[1],
               bytes[index + 2] == headerSeparator[2],
               bytes[index + 3] == headerSeparator[3] {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func shouldClose(version: HTTPVersion, headers: HTTPHeaders) -> Bool {
        let tokens = (headers["connection"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }

        if version == .http10 {
            return !tokens.contains("keep-alive")
        }
        return tokens.contains("close")
    }
}
