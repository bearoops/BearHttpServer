//
//  BearHttpServerTests.swift
//  BearHttpServerTests
//

import Foundation
import Testing
@testable import BearHttpServer

struct BearHttpServerTests {

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
}
