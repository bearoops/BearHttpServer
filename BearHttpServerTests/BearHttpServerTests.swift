//
//  BearHttpServerTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

private enum TestError: Error {
    case missingCertificate
}

struct BearHttpServerTests {

    // MARK: - Helpers

    private func rawResponse(
        port: UInt16,
        request: String = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
    ) async throws -> String {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "bear.test.raw"))
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(request.utf8),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }

        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// Opens a raw TCP connection for tests that need to exchange several
    /// messages in sequence (e.g. the 100-continue handshake).
    private func makeRawConnection(port: UInt16) -> NWConnection {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "bear.test.raw.stream"))
        return connection
    }

    private func sendRaw(_ text: String, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveRaw(from connection: NWConnection) async throws -> String {
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    /// Loads the self-signed test identity shipped beside this test source.
    /// Resolving via `#filePath` works under both SwiftPM and a plain Xcode
    /// test target (where `Bundle.module` is not generated).
    private func testTLSConfiguration() throws -> HTTPServerTLSConfiguration {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let certificateURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("bear_test.p12")
        guard FileManager.default.fileExists(atPath: certificateURL.path) else {
            throw TestError.missingCertificate
        }
        let data = try Data(contentsOf: certificateURL)
        return try HTTPServerTLSConfiguration(pkcs12: data, password: "testpass")
    }

    /// Opens a TLS connection that accepts the self-signed test certificate.
    private func makeTLSConnection(port: UInt16) -> NWConnection {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, DispatchQueue.global())
        let parameters = NWParameters(tls: options)
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        connection.start(queue: DispatchQueue(label: "bear.test.tls"))
        return connection
    }

    private func startObjCServer(_ server: ObjCHTTPServer) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            server.start { port, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: UInt16(port))
                }
            }
        }
    }

    private func stopObjCServer(_ server: ObjCHTTPServer) async {
        await withCheckedContinuation { continuation in
            server.stop { continuation.resume() }
        }
    }

    // MARK: - Core behavior

    @Test func getRequestReturnsConfiguredResponse() async throws {
        let server = HTTPServer { request in
            #expect(request.method == .get)
            #expect(request.target == "/hello")
            return HTTPResponse.text("hello from BearHttpServer")
        }

        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)/hello")!
        let (data, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hello from BearHttpServer")
        await server.stop()
    }

    @Test func postRequestBodyIsDeliveredToHandler() async throws {
        let expected = Data("bear-body".utf8)
        let server = HTTPServer { request in
            #expect(request.method == .post)
            #expect(request.body == expected)
            return HTTPResponse(
                status: .created,
                headers: ["content-type": "application/octet-stream"],
                body: request.body
            )
        }

        let port = try await server.start()
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/echo")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = expected

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        #expect(data == expected)
        await server.stop()
    }

    @Test func serverCanBeRestartedAfterStop() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("ok") }

        _ = try await server.start()
        await server.stop()
        let secondPort = try await server.start()

        let url = URL(string: "http://127.0.0.1:\(secondPort)/")!
        let (data, _) = try await URLSession.shared.data(from: url)

        #expect(String(decoding: data, as: UTF8.self) == "ok")
        await server.stop()
    }

    // MARK: - P0 regressions

    @Test func crlfInjectionIsSanitized() async throws {
        let status = HTTPStatusCode(code: 200, reasonPhrase: "OK\r\nX-Injected1: yes")
        let server = HTTPServer { _ in
            HTTPResponse(
                status: status,
                headers: ["a-test": "a\r\nX-Injected2: yes"],
                body: Data("body".utf8)
            )
        }

        let port = try await server.start()
        let raw = try await rawResponse(port: port)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!status.reasonPhrase.contains("\r"))
        #expect(!status.reasonPhrase.contains("\n"))
        #expect(!raw.contains("\r\nX-Injected1"))
        // Asserting the injected token is absent would be vacuously true: the
        // serializer splits on CRLF and re-prefixes each line, so a bare
        // CRLF+token can never appear. Verify sanitization positively instead:
        // the token must stay on the original header line, after "a-test: a".
        // If CR/LF survived, it would be split into a second line beginning
        // "a-test: X-Injected2" and this check would fail.
        let injectedLine = raw.split(separator: "\r\n").first { $0.contains("X-Injected2") }
        #expect(injectedLine?.hasPrefix("a-test: a") == true)
    }

    @Test func http10RequestGetsHttp10Response() async throws {
        let server = HTTPServer { request in
            #expect(request.version == .http10)
            return HTTPResponse.text("ok")
        }

        let port = try await server.start()
        let request = "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
        let raw = try await rawResponse(port: port, request: request)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.0 200 OK\r\n"))
        #expect(raw.localizedCaseInsensitiveContains("connection: close"))
    }

    @Test func noContentResponseOmitsBodyAndContentLength() async throws {
        let server = HTTPServer { _ in
            HTTPResponse(status: .noContent, body: Data("ignored".utf8))
        }

        let port = try await server.start()
        let raw = try await rawResponse(port: port)
        await server.stop()

        #expect(raw.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(!raw.localizedCaseInsensitiveContains("content-length"))
        #expect(!raw.contains("ignored"))
    }

    @Test func objcHandlerCallingCompletionTwiceReturnsOneResponse() async throws {
        let server = ObjCHTTPServer { _, completion in
            let response = ObjCHTTPResponse.text("once", statusCode: 200)
            completion(response)
            completion(response)
        }

        let port = try await startObjCServer(server)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, response) = try await URLSession.shared.data(from: url)
        await stopObjCServer(server)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "once")
    }

    @Test func objcHandlerTimeoutReturnsGatewayTimeout() async throws {
        let configuration = ObjCHTTPServerConfiguration()
        configuration.handlerTimeout = 0.2
        let server = ObjCHTTPServer(configuration: configuration) { _, _ in
            // Never calls completion: must not hang the request.
        }

        let port = try await startObjCServer(server)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (_, response) = try await URLSession.shared.data(from: url)
        await stopObjCServer(server)

        #expect((response as? HTTPURLResponse)?.statusCode == 504)
    }

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

    // MARK: - TLS and graceful shutdown

    @Test func tlsServerServesHTTPSRequest() async throws {
        var configuration = HTTPServerConfiguration()
        configuration.tls = try testTLSConfiguration()
        let server = HTTPServer(configuration: configuration) { _ in
            HTTPResponse.text("secure hello")
        }
        let port = try await server.start()

        let connection = makeTLSConnection(port: port)
        defer { connection.cancel() }
        try await sendRaw(
            "GET /secure HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            on: connection
        )
        let response = try await receiveRaw(from: connection)
        await server.stop()

        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.hasSuffix("secure hello"))
    }

    @Test func invalidPKCS12ReportsConfigurationError() {
        let data = Data("not a pkcs12 bundle".utf8)
        #expect(throws: HTTPServerError.self) {
            _ = try HTTPServerTLSConfiguration(pkcs12: data, password: "wrong")
        }
    }

    @Test func gracefulShutdownWaitsForInFlightRequest() async throws {
        let started = Signal()
        let server = HTTPServer { _ in
            await started.fire()
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s
            return HTTPResponse.text("finished")
        }
        let port = try await server.start()

        // Fire a request and, once the handler is running, stop the server.
        let requestTask = Task {
            let url = URL(string: "http://127.0.0.1:\(port)/slow")!
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(decoding: data, as: UTF8.self)
        }
        await started.wait()
        let stopStarted = Date()
        await server.stop()
        let elapsed = Date().timeIntervalSince(stopStarted)
        let body = try await requestTask.value

        #expect(body == "finished")
        #expect(elapsed >= 0.1)
    }

    @Test func stopClosesIdleConnectionsImmediately() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("ok") }
        let port = try await server.start()

        // Open a keep-alive connection so an idle session exists.
        let connection = makeRawConnection(port: port)
        try await sendRaw("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", on: connection)
        _ = try await receiveRaw(from: connection)

        let stopStarted = Date()
        await server.stop()
        let elapsed = Date().timeIntervalSince(stopStarted)
        connection.cancel()

        #expect(elapsed < 2)
    }

    // MARK: - 守约测试（P0：响应语义）

    @Test func headResponseHasNoBodyButKeepsContentLength() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("hello-body") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: "HEAD / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("content-length: 10"))
        // 头之后不能有 body
        guard let separator = response.range(of: "\r\n\r\n") else {
            Issue.record("missing header terminator")
            return
        }
        let body = response[separator.upperBound...]
        #expect(body.isEmpty)
    }

    @Test func dateHeaderUsesRFC1123Format() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("ok") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port)
        let lines = response.split(separator: "\r\n", omittingEmptySubsequences: false)
        let dateLine = lines.first { $0.lowercased().hasPrefix("date:") }
        #expect(dateLine != nil)
        let value = dateLine?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        // RFC 1123: "Wed, 21 Oct 2015 07:28:00 GMT" —— 含星期、逗号、GMT 后缀
        #expect(value.contains(","))
        #expect(value.hasSuffix("GMT"))
        let expectedFormat = DateFormatter()
        expectedFormat.locale = Locale(identifier: "en_US_POSIX")
        expectedFormat.timeZone = TimeZone(secondsFromGMT: 0)
        expectedFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(expectedFormat.date(from: value) != nil)
    }

    @Test func defaultHandlerReturns404() async throws {
        // 不传 handler → 默认返回 404
        let server = HTTPServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port)
        #expect(response.hasPrefix("HTTP/1.1 404 Not Found"))
    }

    @Test func duplicateContentLengthReturns400() async throws {
        let server = HTTPServer { _ in HTTPResponse.text("ok") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
        )
        #expect(response.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    // MARK: - 守约测试（P0：连接资源）

    @Test func maxConnectionsLimitRejectsExtraConnections() async throws {
        var configuration = HTTPServerConfiguration.localhost
        configuration.maxConnections = 1
        let server = HTTPServer(configuration: configuration) { _ in HTTPResponse.text("ok") }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        // 第一条连接占住名额（keep-alive，不关）
        let first = makeRawConnection(port: port)
        defer { first.cancel() }
        try await sendRaw("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", on: first)
        _ = try await receiveRaw(from: first)

        // 第二条连接即使 TCP 层 ready，服务端也不会为它建立 session，
        // 因此发出的请求收不到响应。用"能否收到响应"判定名额上限，
        // 比断言瞬时 connection.state 更稳定（TCP ready 早于服务端 accept）。
        let second = makeRawConnection(port: port)
        defer { second.cancel() }
        try await sendRaw("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", on: second)
        let oneShot = OnceFlag()
        let responded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            second.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if oneShot.claim() {
                    c.resume(returning: (data?.isEmpty == false) && error == nil)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
                if oneShot.claim() {
                    c.resume(returning: false)
                }
            }
        }
        #expect(!responded)
    }

    @Test func idleConnectionIsClosedAfterTimeout() async throws {
        var configuration = HTTPServerConfiguration.localhost
        configuration.connectionIdleTimeout = 0.5
        let server = HTTPServer(configuration: configuration) { _ in HTTPResponse.text("ok") }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }
        // 建连后不发任何字节，等待服务端 idle guard 触发 cancel
        // 服务端 cancel socket 后，客户端挂起的 receive 会带 error/nil 返回。
        // 用 receive 判定比 stateUpdateHandler 可靠（后者在连接已 ready 后
        // 才设置时可能已错过早期状态变化）。
        let oneShot = OnceFlag()
        let ended = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if oneShot.claim() {
                    c.resume(returning: error != nil || isComplete)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                if oneShot.claim() { c.resume(returning: false) }
            }
        }
        #expect(ended)
    }
}

/// Thread-safe one-shot flag for network callbacks racing a timeout task.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

/// A minimal one-shot signal used to coordinate tests with a running handler.
private actor Signal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
