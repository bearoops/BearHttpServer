//
//  StreamingBodyTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

struct StreamingBodyTests {

    // MARK: - Request side

    @Test func streamingHandlerReadsBodyInChunks() async throws {
        let received = LockedData()
        let chunksSeen = LockedCounter()
        let server = HTTPServer(streamingHandler: { _, stream in
            while let chunk = try? await stream.read() {
                received.append(chunk)
                chunksSeen.bump()
            }
            return .text("done")
        })
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }
        // Split the body across several TCP writes.
        try await sendRaw(
            "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\n",
            on: connection
        )
        try await sendRaw("hello ", on: connection)
        try await sendRaw("world", on: connection)
        let response = try await receiveRaw(from: connection)
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(received.get() == Data("hello world".utf8))
        #expect(chunksSeen.value >= 2)
    }

    @Test func streamingHandlerProcessesBeforeBodyCompletes() async throws {
        let gate = Signal()
        let firstChunkSeen = Signal()
        let server = HTTPServer(streamingHandler: { _, stream in
            if let first = try? await stream.read() { _ = first }
            await firstChunkSeen.fire()
            // Wait for the test to release us after confirming early read.
            await gate.wait()
            // Drain the remaining declared body so the connection can finish.
            while let _ = try? await stream.read() {}
            return .text("early")
        })
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }
        try await sendRaw(
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n",
            on: connection
        )
        try await sendRaw("first", on: connection)
        // Handler should observe the first chunk even though 95 bytes of the
        // declared body have not arrived yet.
        await firstChunkSeen.wait()
        await gate.fire()
        try await sendRaw(String(repeating: "x", count: 95), on: connection)
        let response = try await receiveRaw(from: connection)
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func streamingBodyOverLimitFailsRead() async throws {
        let errorSeen = LockedFlag()
        var configuration = HTTPServerConfiguration.localhost
        configuration.maxBodyBytes = 5
        let server = HTTPServer(configuration: configuration) { _, stream in
            do {
                while true {
                    guard let _ = try await stream.read() else { break }
                }
            } catch {
                errorSeen.set()
            }
            return .text("ok")
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }
        try await sendRaw(
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 20\r\n\r\n",
            on: connection
        )
        try await sendRaw("this is way too long", on: connection)
        _ = try await receiveRaw(from: connection)
        #expect(errorSeen.get())
    }

    @Test func chunkedRequestOnStreamingHandlerReturns501() async throws {
        let server = HTTPServer(streamingHandler: { _, _ in .text("never") })
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 501 Not Implemented"))
    }

    // MARK: - Response side

    @Test func streamingResponseSendsMultipleChunks() async throws {
        let chunks = ["hello ", "streamed ", "world"]
        let index = LockedCounter()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, headers: ["content-type": "text/plain"], bodyStream: {
                if index.bumpAndGet() < chunks.count {
                    let i = index.value - 1
                    return Data(chunks[i].utf8)
                }
                return nil
            })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("transfer-encoding: chunked"))
        #expect(response.contains("hello "))
        #expect(response.contains("streamed "))
        #expect(response.contains("world"))
        #expect(response.contains("0\r\n\r\n"))
    }

    @Test func streamingResponseHasBackPressure() async throws {
        let order = LockedStrings()
        let pulls = LockedCounter()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: {
                let n = pulls.bumpAndGet()
                order.append("pull-\(n)")
                return n < 3 ? Data("chunk\(n + 1)".utf8) : nil
            })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        _ = try await rawResponse(port: port)
        #expect(order.get() == ["pull-0", "pull-1", "pull-2", "pull-3"])
    }

    @Test func streamingResponseDecodesCorrectlyOverURLSession() async throws {
        let chunks = ["stream-", "ing-", "works"]
        let counter = LockedCounter()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: {
                let i = counter.bumpAndGet()
                return i < chunks.count ? Data(chunks[i].utf8) : nil
            })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "stream-ing-works")
    }

    @Test func headWithStreamingResponseHasNoBody() async throws {
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: { Data("secret".utf8) })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: "HEAD / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        guard let separator = response.range(of: "\r\n\r\n") else {
            Issue.record("missing header terminator")
            return
        }
        #expect(response[separator.upperBound...].isEmpty)
    }

    @Test func http10StreamingResponseFallsBackToContentLength() async throws {
        let sent = LockedFlag()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: {
                if sent.get() { return nil }
                sent.set()
                return Data("legacy".utf8)
            })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.0 200 OK"))
        #expect(response.contains("content-length: 6"))
        #expect(response.contains("legacy"))
        #expect(!response.contains("transfer-encoding"))
    }
}

// MARK: - Thread-safe test utilities

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; storage.append(chunk) }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); defer { lock.unlock() }; flag = true }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); defer { lock.unlock() }; n += 1 }
    func bumpAndGet() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n - 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); defer { lock.unlock() }; items.append(s) }
    func get() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}
