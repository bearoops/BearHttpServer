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
        let received = ChunkCollector()
        let server = HTTPServer(streamingHandler: { _, stream in
            while let chunk = try? await stream.read() {
                await received.append(chunk)
            }
            return .text("done")
        })
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let connection = makeRawConnection(port: port)
        defer { connection.cancel() }
        // Two writes may coalesce into one TCP segment (or arrive as several)
        // — TCP does not preserve write boundaries. Assert only that every
        // byte is delivered through the stream; chunk boundaries are covered
        // by streamingHandlerProcessesBeforeBodyCompletes.
        try await sendRaw(
            "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\n\r\n",
            on: connection
        )
        try await sendRaw("hello ", on: connection)
        try await sendRaw("world", on: connection)
        let response = try await receiveRaw(from: connection)
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(await received.get() == Data("hello world".utf8))
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
        let errorSeen = Flag()
        var configuration = HTTPServerConfiguration.localhost
        configuration.maxBodyBytes = 5
        let server = HTTPServer(configuration: configuration) { _, stream in
            do {
                while true {
                    guard let _ = try await stream.read() else { break }
                }
            } catch {
                await errorSeen.set()
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
        #expect(await errorSeen.get())
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
        let index = Counter()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, headers: ["content-type": "text/plain"], bodyStream: {
                let i = await index.bumpAndGet()
                return i < chunks.count ? Data(chunks[i].utf8) : nil
            })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        // Chunks are sent in separate writes; drain until close so a partial
        // first receive cannot hide later chunks.
        let response = try await rawResponse(
            port: port,
            request: "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
            readUntilComplete: true
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("transfer-encoding: chunked"))
        #expect(response.contains("hello "))
        #expect(response.contains("streamed "))
        #expect(response.contains("world"))
        #expect(response.contains("0\r\n\r\n"))
    }

    @Test func streamingResponseHasBackPressure() async throws {
        let order = EventLog()
        let pulls = Counter()
        let streamDrained = Signal()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: {
                let n = await pulls.bumpAndGet()
                await order.append("pull-\(n)")
                if n >= 3 { await streamDrained.fire() }
                return n < 3 ? Data("chunk\(n + 1)".utf8) : nil
            })
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        _ = try await rawResponse(port: port)
        // The client may read a partial response before the final pull (which
        // returns nil) happens, so wait for the stream to be fully drained.
        await streamDrained.wait()
        let events = await order.get()
        #expect(events == ["pull-0", "pull-1", "pull-2", "pull-3"])
    }

    @Test func streamingResponseDecodesCorrectlyOverURLSession() async throws {
        let chunks = ["stream-", "ing-", "works"]
        let counter = Counter()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: {
                let i = await counter.bumpAndGet()
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
        let sent = Flag()
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, bodyStream: {
                if await sent.get() { return nil }
                await sent.set()
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

private actor ChunkCollector {
    private var storage = Data()
    func append(_ chunk: Data) { storage.append(chunk) }
    func get() -> Data { storage }
}

private actor Flag {
    private var flag = false
    func set() { flag = true }
    func get() -> Bool { flag }
}

private actor Counter {
    private var n = 0
    func bump() { n += 1 }
    func bumpAndGet() -> Int { n += 1; return n - 1 }
    var value: Int { n }
}

private actor EventLog {
    private var items: [String] = []
    func append(_ s: String) { items.append(s) }
    func get() -> [String] { items }
}
