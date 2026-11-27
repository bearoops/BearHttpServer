//
//  HTTPConnection.swift
//  BearHttpServer
//

import Foundation
import Network

/// Shared RFC 1123 date formatter. Constructing a `DateFormatter` on every
/// response is expensive, so a single instance is reused. As an actor it
/// serializes access without a lock, which also keeps `DateFormatter` (a
/// non-Sendable type) confined to one isolation domain.
private actor HTTPDateFormatter {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

/// Cancels a connection after a stretch of inactivity. Arm before waiting for
/// more bytes, disarm as soon as bytes arrive; cancelling makes the pending
/// `NWConnection.receive` completion return an error and end the session.
/// An actor serializes arm/disarm, and a cancellable `Task` replaces the old
/// dispatch work item so the timeout uses structured concurrency throughout.
private actor IdleTimeoutGuard {
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var work: Task<Void, Never>?

    init(connection: NWConnection, timeout: TimeInterval) {
        self.connection = connection
        self.timeout = timeout
    }

    func arm() {
        guard timeout > 0 else { return }
        work?.cancel()
        let socket = connection
        work = Task {
            // A cancelled sleep throws; return so disarm/arm cannot leave a
            // stale timer that cancels a socket which has since seen traffic.
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            socket.cancel()
        }
    }

    func disarm() {
        work?.cancel()
        work = nil
    }
}

/// Answers a pending handler continuation exactly once — the handler path and
/// the timeout path race, and whichever reaches `complete` first wins.
/// `complete` may arrive before `install`; the response is buffered until a
/// continuation is installed.
private actor HandlerResponseOnce {
    private var continuation: CheckedContinuation<HTTPResponse, Never>?
    private var pending: HTTPResponse?

    func install(_ c: CheckedContinuation<HTTPResponse, Never>) {
        if let pending {
            self.pending = nil
            c.resume(returning: pending)
        } else {
            continuation = c
        }
    }

    func complete(_ response: HTTPResponse) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: response)
        } else {
            pending = response
        }
    }
}

final class HTTPConnection: @unchecked Sendable {
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private static let headerSeparator: [UInt8] = [13, 10, 13, 10] // CRLF CRLF

    private let connection: NWConnection
    private let configuration: HTTPServerConfiguration
    private let gate: ConnectionGate
    private let handler: RequestHandler

    init(
        connection: NWConnection,
        configuration: HTTPServerConfiguration,
        gate: ConnectionGate,
        handler: @escaping RequestHandler
    ) {
        self.connection = connection
        self.configuration = configuration
        self.gate = gate
        self.handler = handler
    }

    func run() async {
        var buffer = Data()
        let idleGuard = IdleTimeoutGuard(
            connection: connection,
            timeout: configuration.connectionIdleTimeout
        )
        // Once the session ends, actively close the socket instead of relying
        // on deallocation. This is what makes `Connection: close` effective.
        // Swift forbids `await` inside `defer`, so hop to a task to disarm the
        // actor on every exit; cancelling the socket ends any pending receive
        // immediately regardless.
        defer {
            Task { await idleGuard.disarm() }
            connection.cancel()
        }

        // A client using `Expect: 100-continue` withholds its body until the
        // server grants permission. Track whether we have already done so for
        // the request currently in the buffer: a body can arrive in several
        // TCP segments, each producing another `.needMore`, but the interim
        // response must be sent only once per request.
        var continueSent = false

        while true {
            switch Self.parseNextRequest(from: &buffer, configuration: configuration) {
            case .request(let request, let closeAfterResponse):
                // A graceful stop may have begun while we were waiting for
                // bytes. Do not start a new request once draining; finish the
                // current one and let the session wind down.
                guard await gate.beginRequest() else { return }
                continueSent = false
                let response = await Self.invokeHandler(
                    request,
                    timeout: configuration.handlerTimeout,
                    handler: handler
                )
                let shouldContinue = await send(
                    response,
                    version: request.version,
                    close: closeAfterResponse,
                    includeBody: request.method != .head
                )
                let shouldDrain = await gate.endRequest()
                if !shouldContinue || shouldDrain {
                    return
                }

            case .error(let status, let message, let version):
                await sendError(status: status, message: message, version: version)
                return

            case .needMore(let wantsContinue):
                if wantsContinue && !continueSent {
                    continueSent = true
                    await sendContinue()
                }
                await idleGuard.arm()
                do {
                    let (chunk, isComplete) = try await receive()
                    await idleGuard.disarm()
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

    /// Grants a client's `Expect: 100-continue` so it will start sending the
    /// body. Interim responses carry only a status line and an empty header
    /// block — no `Date` or `Server` fields — per RFC 7230 section 2.6.
    private func sendContinue() async {
        let payload = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        try? await sendAll(payload)
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
    private func send(
        _ response: HTTPResponse,
        version: HTTPVersion,
        close: Bool,
        includeBody: Bool
    ) async -> Bool {
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
        // Echo the request's HTTP version. An HTTP/1.0 client must receive an
        // HTTP/1.0 status line, not one claiming HTTP/1.1.
        payload.append(contentsOf: "\(version.rawValue) \(status.code) \(reasonPhrase)\r\n".utf8)

        var headers = response.headers
        headers["server"] = configuration.serverHeader
        headers["date"] = await Self.currentHTTPDate()

        // Chunked output is opt-in: a handler signals it with
        // `transfer-encoding: chunked`. HTTP/1.0 does not understand chunked,
        // and HEAD/1xx/204/304 cannot carry body framing, so those cases fall
        // back to Content-Length. This keeps existing handlers unchanged.
        let requestedChunked = Self.wantsChunked(headers)
        let useChunked = statusAllowsBody && includeBody && version == .http11 && requestedChunked
        if useChunked {
            headers["transfer-encoding"] = "chunked"
            headers["content-length"] = nil
        } else {
            headers["transfer-encoding"] = nil
            headers["content-length"] = statusAllowsBody ? String(bodyForLength.count) : nil
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

        if useChunked {
            payload.append(Self.chunkedEncoded(bodyToSend))
        } else if !bodyToSend.isEmpty {
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

    /// Whether the handler opted into chunked output via the header. Accepts
    /// comma-separated tokens case-insensitively, mirroring request parsing.
    private static func wantsChunked(_ headers: HTTPHeaders) -> Bool {
        guard let encoding = headers["transfer-encoding"] else { return false }
        return encoding
            .split(separator: ",")
            .contains { String($0).trimmingCharacters(in: .whitespaces).lowercased() == "chunked" }
    }

    /// Formats a body as RFC 7230 chunks: each chunk is `<hex length> CRLF
    /// <data> CRLF`, followed by a zero-length chunk and the final CRLF.
    private static func chunkedEncoded(_ body: Data) -> Data {
        var encoded = Data()
        // A single chunk holding the entire body is valid and avoids extra
        // copies; handlers needing true streaming will be handled at P1.
        let length = String(body.count, radix: 16)
        encoded.append(contentsOf: length.utf8)
        encoded.append(contentsOf: [13, 10])
        encoded.append(body)
        encoded.append(contentsOf: [13, 10])
        encoded.append(contentsOf: "0\r\n\r\n".utf8)
        return encoded
    }

    private func sendError(
        status: HTTPStatusCode,
        message: String,
        version: HTTPVersion
    ) async {
        _ = await send(
            HTTPResponse.text(message, status: status),
            version: version,
            close: true,
            includeBody: true
        )
    }

    private static let dateFormatter = HTTPDateFormatter()

    private static func currentHTTPDate() async -> String {
        await dateFormatter.string(from: Date())
    }

    /// Invokes `handler` with an optional deadline. When `timeout <= 0` the
    /// handler runs directly (zero overhead, existing behavior). Otherwise a
    /// detached timer races the handler and answers 504 if it wins; the timer
    /// is cancelled as soon as the handler responds.
    private static func invokeHandler(
        _ request: HTTPRequest,
        timeout: TimeInterval,
        handler: @escaping RequestHandler
    ) async -> HTTPResponse {
        guard timeout > 0 else { return await handler(request) }

        let once = HandlerResponseOnce()
        let task = Task {
            let response = await handler(request)
            await once.complete(response)
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return // cancelled because the handler already answered
            }
            await once.complete(
                HTTPResponse.text("Request handler timed out.", status: .gatewayTimeout)
            )
        }
        let response = await withCheckedContinuation { (c: CheckedContinuation<HTTPResponse, Never>) in
            Task { await once.install(c) }
        }
        timer.cancel()
        task.cancel()
        return response
    }

    private enum ParseResult {
        /// The parser needs more bytes. The associated value is true when the
        /// request announced `Expect: 100-continue` and we should grant it
        /// before waiting for the body.
        case needMore(wantsContinue: Bool)
        case request(HTTPRequest, close: Bool)
        case error(HTTPStatusCode, String, HTTPVersion)
    }

    /// Outcome of decoding a chunked request body.
    private enum ChunkedResult {
        case needMore
        /// Fully decoded body plus the index just past the terminating chunk.
        case complete(body: Data, end: Int)
        case error(HTTPStatusCode, String)
    }

    private static func parseNextRequest(
        from buffer: inout Data,
        configuration: HTTPServerConfiguration
    ) -> ParseResult {
        guard let headerEnd = findHeaderEnd(in: buffer) else {
            if buffer.count > configuration.maxHeaderBytes {
                return .error(.requestHeaderFieldsTooLarge, "Request headers are too large.", .http11)
            }
            // The header block is incomplete, so we cannot know whether
            // `Expect` is present yet.
            return .needMore(wantsContinue: false)
        }

        if headerEnd > configuration.maxHeaderBytes {
            return .error(.requestHeaderFieldsTooLarge, "Request headers are too large.", .http11)
        }

        let bodyStart = headerEnd + headerSeparator.count
        guard let headerText = String(
            data: buffer.subdata(in: 0..<headerEnd),
            encoding: .utf8
        ) else {
            return .error(.badRequest, "Request headers are not valid UTF-8.", .http11)
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return .error(.badRequest, "Missing request line.", .http11)
        }

        let components = requestLine.split(
            separator: " ",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard components.count == 3 else {
            return .error(.badRequest, "Malformed request line.", .http11)
        }

        let method = HTTPMethod(rawValue: String(components[0]))
        let target = String(components[1])
        let version = HTTPVersion(rawValue: String(components[2]))

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                return .error(.badRequest, "Malformed request header.", version)
            }
            let name = String(pair[0]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return .error(.badRequest, "Malformed request header name.", version)
            }
            headers.append(name, value: value)
        }

        // `Expect: 100-continue` is an HTTP/1.1 feature. We only grant it once
        // the header block is complete and we know a body is actually coming;
        // if the request is rejected for size or framing, a final status is
        // sent instead, which is the RFC 7231 behavior.
        let wantsContinue = version == .http11 && expectsContinue(headers)

        let transferCodings = (headers["transfer-encoding"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let isChunked = transferCodings.contains("chunked")

        let body: Data
        let requestEnd: Int

        if isChunked {
            // Only the `chunked` coding is implemented. Anything else (gzip,
            // deflate, ...) cannot be decoded, so fail rather than hand raw
            // framed bytes to the handler.
            guard transferCodings.count == 1 else {
                return .error(.notImplemented, "Unsupported transfer encoding.", version)
            }
            // Advertising both framing mechanisms is a request-smuggling
            // vector. Reject it instead of guessing which one wins.
            guard headers["content-length"] == nil else {
                return .error(.badRequest, "Conflicting Content-Length and Transfer-Encoding.", version)
            }
            switch decodeChunkedBody(
                in: buffer,
                from: bodyStart,
                configuration: configuration
            ) {
            case .needMore:
                return .needMore(wantsContinue: wantsContinue)
            case .error(let status, let message):
                return .error(status, message, version)
            case .complete(let decoded, let end):
                body = decoded
                requestEnd = end
            }
        } else {
            var contentLength = 0
            if let rawContentLength = headers["content-length"] {
                let trimmed = rawContentLength.trimmingCharacters(in: .whitespaces)
                guard let value = Int(trimmed), value >= 0 else {
                    return .error(.badRequest, "Invalid Content-Length.", version)
                }
                contentLength = value
            }

            guard contentLength <= configuration.maxBodyBytes else {
                return .error(.payloadTooLarge, "Request body is too large.", version)
            }
            guard contentLength <= Int.max - bodyStart else {
                return .error(.payloadTooLarge, "Request body is too large.", version)
            }

            let end = bodyStart + contentLength
            guard buffer.count >= end else {
                return .needMore(wantsContinue: wantsContinue)
            }
            body = Data(buffer.subdata(in: bodyStart..<end))
            requestEnd = end
        }

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

    /// Whether the request asks the server to grant `Expect: 100-continue`.
    /// Values are comma-separated tokens and compared case-insensitively.
    private static func expectsContinue(_ headers: HTTPHeaders) -> Bool {
        guard let expect = headers["expect"] else { return false }
        return expect
            .split(separator: ",")
            .contains { String($0).trimmingCharacters(in: .whitespaces).lowercased() == "100-continue" }
    }

    /// Maximum size of a single chunk-size or trailer line. Chunk frames are
    /// framing metadata, not payload, so a small cap prevents a client from
    /// streaming unbounded bytes without completing a request.
    private static let maxChunkLineBytes = 8 * 1024

    /// Decodes an RFC 7230 chunked body: repeated
    /// `<hex size>[;extension] CRLF <data> CRLF`, terminated by a zero-sized
    /// chunk followed by an (optional) trailer section and a blank line.
    /// Trailers are consumed for correct framing but are not exposed on
    /// `HTTPRequest`; only the decoded body octets are returned.
    private static func decodeChunkedBody(
        in buffer: Data,
        from start: Int,
        configuration: HTTPServerConfiguration
    ) -> ChunkedResult {
        var cursor = start
        var body = Data()

        while true {
            guard let lineEnd = findCRLF(in: buffer, from: cursor) else {
                if buffer.count - cursor > maxChunkLineBytes {
                    return .error(.badRequest, "Chunk size line is too large.")
                }
                return .needMore
            }
            guard lineEnd - cursor <= maxChunkLineBytes else {
                return .error(.badRequest, "Chunk size line is too large.")
            }
            guard let line = String(data: buffer.subdata(in: cursor..<lineEnd), encoding: .utf8),
                  let sizeToken = line
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first?
                    .trimmingCharacters(in: .whitespaces),
                  !sizeToken.isEmpty,
                  sizeToken.allSatisfy(\.isHexDigit),
                  let size = Int(sizeToken, radix: 16) else {
                return .error(.badRequest, "Invalid chunk size.")
            }

            cursor = lineEnd + 2

            if size == 0 {
                // Consume trailers up to and including the terminating blank
                // line. Each line must end in CRLF; the first empty line ends
                // the section.
                let trailerStart = cursor
                while true {
                    guard let trailerEnd = findCRLF(in: buffer, from: cursor) else {
                        if buffer.count - trailerStart > configuration.maxHeaderBytes {
                            return .error(.requestHeaderFieldsTooLarge, "Chunk trailers are too large.")
                        }
                        return .needMore
                    }
                    if trailerEnd - trailerStart > configuration.maxHeaderBytes {
                        return .error(.requestHeaderFieldsTooLarge, "Chunk trailers are too large.")
                    }
                    if trailerEnd == cursor {
                        return .complete(body: body, end: trailerEnd + 2)
                    }
                    cursor = trailerEnd + 2
                }
            }

            // Reject oversized chunks before waiting for their bytes so a
            // hostile size cannot make us buffer far beyond the limit.
            guard size <= configuration.maxBodyBytes - body.count,
                  size <= Int.max - cursor - 2 else {
                return .error(.payloadTooLarge, "Request body is too large.")
            }
            let chunkEnd = cursor + size
            guard chunkEnd + 2 <= buffer.count else {
                return .needMore
            }
            guard buffer[chunkEnd] == 13, buffer[chunkEnd + 1] == 10 else {
                return .error(.badRequest, "Malformed chunk terminator.")
            }
            body.append(buffer.subdata(in: cursor..<chunkEnd))
            cursor = chunkEnd + 2
        }
    }

    /// Finds the first CRLF at or after `start`, returning the index of the CR.
    private static func findCRLF(in data: Data, from start: Int) -> Int? {
        guard start >= 0, start < data.count else { return nil }
        var index = start
        while index < data.count - 1 {
            if data[index] == 13, data[index + 1] == 10 {
                return index
            }
            index += 1
        }
        return nil
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
