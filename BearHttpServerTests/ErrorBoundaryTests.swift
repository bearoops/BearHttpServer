//
//  ErrorBoundaryTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

struct ErrorBoundaryTests {
    // MARK: - Error paths and boundaries

    // MARK: - Error paths and boundaries

    @Test func chunkedRequestBodyIsDeliveredToHandler() async throws {
        let expected = Data("hello chunked world".utf8)
        let server = HTTPServer { request in
            #expect(request.method == .post)
            #expect(request.body == expected)
            #expect(request.headers["transfer-encoding"] == "chunked")
            return HTTPResponse.text("ok")
        }
        let port = try await server.start()
        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }

        // Send the request as separate TCP writes so the body genuinely
        // arrives in pieces. The pauses keep the writes in distinct reads and
        // force the parser through its incremental (.needMore) path — writing
        // the whole request at once would only test a complete buffered body.
        // The first chunk's size line is itself split across two writes to
        // cover a partially received framing line.
        let writes = [
            "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5;ext",                   // partial chunk-size line
            "=value\r\n",              // remainder of that line, with an extension
            "hello\r\n",               // first chunk data
            "E\r\n chunked world\r\n", // second chunk
            "0\r\n",                   // last chunk
            "X-Checksum: abc\r\n\r\n", // trailer section
        ]
        for write in writes {
            try await sendRaw(write, on: connection)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let response = try await receiveRaw(from: connection)
        await server.stop()

        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func invalidChunkSizeIsRejected() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let request = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\nbody\r\n0\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    @Test func conflictingContentLengthAndChunkedIsRejected() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let request = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    @Test func oversizedChunkedBodyIsRejected() async throws {
        let configuration = HTTPServerConfiguration(maxBodyBytes: 4)
        let server = HTTPServer(configuration: configuration) { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let request = "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n64\r\n\(String(repeating: "x", count: 100))\r\n0\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 413 Payload Too Large"))
    }

    @Test func chunkedResponseUsesChunkedEncoding() async throws {
        let server = HTTPServer { _ in
            HTTPResponse(headers: ["transfer-encoding": "chunked"], body: Data("abc".utf8))
        }
        let port = try await server.start()
        let raw = try await rawResponse(port: port)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 200 OK"))
        #expect(raw.localizedCaseInsensitiveContains("transfer-encoding: chunked"))
        #expect(!raw.localizedCaseInsensitiveContains("content-length"))
        #expect(raw.hasSuffix("3\r\nabc\r\n0\r\n\r\n"))
    }

    @Test func expectContinueGrants100ThenDeliversBody() async throws {
        let expected = Data("payload".utf8)
        let server = HTTPServer { request in
            #expect(request.body == expected)
            return HTTPResponse.text("received")
        }
        let port = try await server.start()
        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }

        // Client announces the body but waits for 100 Continue before sending it.
        try await sendRaw(
            "POST /upload HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 7\r\n\r\n",
            on: connection
        )
        let interim = try await receiveRaw(from: connection)
        #expect(interim.hasPrefix("HTTP/1.1 100 Continue\r\n\r\n"))

        try await sendRaw("payload", on: connection)
        let final = try await receiveRaw(from: connection)
        await server.stop()

        #expect(final.hasPrefix("HTTP/1.1 200 OK"))
        #expect(final.hasSuffix("received"))
    }

    @Test func oversizedBodyWithExpectContinueIsRejectedWithout100() async throws {
        let configuration = HTTPServerConfiguration(maxBodyBytes: 4)
        let server = HTTPServer(configuration: configuration) { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }

        try await sendRaw(
            "POST /upload HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 100\r\n\r\n",
            on: connection
        )
        let response = try await receiveRaw(from: connection)
        await server.stop()

        #expect(response.hasPrefix("HTTP/1.1 413 Payload Too Large"))
    }

    @Test func http10ErrorResponseUsesHttp10StatusLine() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let request = "POST / HTTP/1.0\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.0 400 Bad Request"))
    }

    @Test func oversizedHeadersAreRejected() async throws {
        let configuration = HTTPServerConfiguration(maxHeaderBytes: 128)
        let server = HTTPServer(configuration: configuration) { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Large: \(String(repeating: "a", count: 256))\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 431 Request Header Fields Too Large"))
    }

    @Test func oversizedBodyIsRejected() async throws {
        let configuration = HTTPServerConfiguration(maxBodyBytes: 4)
        let server = HTTPServer(configuration: configuration) { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let body = String(repeating: "x", count: 100)
        let request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n\(body)"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 413 Payload Too Large"))
    }

    @Test func invalidContentLengthIsRejected() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("unexpected") }
        let port = try await server.start()
        let request = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    @Test func keepAliveConnectionServesMultipleRequests() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("ok") }
        let port = try await server.start()
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "bear.test.keepalive"))
        defer { connection.cancel() }

        func exchange(_ request: String) async throws -> String {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) })
                    }
                }
            } ?? ""
        }

        let first = try await exchange("GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let second = try await exchange("GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        await server.stop()

        #expect(first.hasPrefix("HTTP/1.1 200 OK"))
        #expect(first.localizedCaseInsensitiveContains("connection: keep-alive"))
        #expect(second.hasPrefix("HTTP/1.1 200 OK"))
        #expect(second.localizedCaseInsensitiveContains("connection: close"))
    }

    @Test func concurrentRequestsAreAllServed() async throws {
        let server = HTTPServer { request in HTTPResponse.text(request.target) }
        let port = try await server.start()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let url = URL(string: "http://127.0.0.1:\(port)/\(index)")!
                    let (data, _) = try await URLSession.shared.data(from: url)
                    return String(decoding: data, as: UTF8.self)
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        await server.stop()

        #expect(results.count == 20)
        #expect(Set(results).count == 20)
    }

    @Test func ipv6LoopbackBindingWorks() async throws {
        let server = HTTPServer(configuration: HTTPServerConfiguration(host: "::1")) { _ in
            HTTPResponse.text("ipv6")
        }
        let port = try await server.start()
        let url = URL(string: "http://[::1]:\(port)/")!
        let (data, _) = try await URLSession.shared.data(from: url)
        await server.stop()

        #expect(String(decoding: data, as: UTF8.self) == "ipv6")
    }

    @Test func objcInvalidPortReportsConfigurationError() async throws {
        let configuration = ObjCHTTPServerConfiguration()
        configuration.port = 70000
        let server = ObjCHTTPServer(configuration: configuration) { _, completion in
            completion(ObjCHTTPResponse.text("unexpected", statusCode: 200))
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<(Int, NSError?), Never>) in
            server.start { port, error in continuation.resume(returning: (port, error)) }
        }

        #expect(result.1?.code == ObjCHTTPServerErrorCode.invalidConfiguration.rawValue)
    }
}
