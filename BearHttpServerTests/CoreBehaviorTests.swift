//
//  CoreBehaviorTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

struct CoreBehaviorTests {
    // MARK: - Core behavior and P0 regressions

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
}
