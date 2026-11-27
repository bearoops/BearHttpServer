//
//  TLSAndShutdownTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

struct TLSAndShutdownTests {
    // MARK: - TLS and graceful shutdown

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
}
