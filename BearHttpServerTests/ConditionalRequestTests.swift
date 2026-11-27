//
//  ConditionalRequestTests.swift
//  BearHttpServerTests
//

import Foundation
import Testing
@testable import BearHttpServer

struct ConditionalRequestTests {
    private func request(_ extra: String = "", method: String = "GET") -> String {
        "\(method) / HTTP/1.1\r\nHost: localhost\r\n\(extra)Connection: close\r\n\r\n"
    }

    private func etag(from response: String) -> String? {
        let line = response.split(separator: "\r\n").first {
            $0.lowercased().hasPrefix("etag:")
        }
        return line?.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces)
    }

    @Test func responseCarriesGeneratedETag() async throws {
        let server = HTTPServer { _ in .text("hello") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port, request: request())
        let tag = etag(from: response)
        #expect(tag != nil)
        #expect(tag?.hasPrefix("\"") == true)
        #expect(tag?.hasSuffix("\"") == true)
    }

    @Test func matchingIfNoneMatchReturns304() async throws {
        let server = HTTPServer { _ in .text("hello") }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let first = try await rawResponse(port: port, request: request())
        let tag = etag(from: first)!
        let second = try await rawResponse(
            port: port,
            request: request("If-None-Match: \(tag)\r\n")
        )
        #expect(second.hasPrefix("HTTP/1.1 304 Not Modified"))
        #expect(etag(from: second) == tag)
        // 304 无 body
        guard let separator = second.range(of: "\r\n\r\n") else {
            Issue.record("missing header terminator")
            return
        }
        #expect(second[separator.upperBound...].isEmpty)
    }

    @Test func nonMatchingIfNoneMatchReturns200() async throws {
        let server = HTTPServer { _ in .text("hello") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: request("If-None-Match: \"nope\"\r\n")
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("hello"))
    }

    @Test func starIfNoneMatchReturns304() async throws {
        let server = HTTPServer { _ in .text("hello") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: request("If-None-Match: *\r\n")
        )
        #expect(response.hasPrefix("HTTP/1.1 304 Not Modified"))
    }

    @Test func weakETagUsesWeakComparison() async throws {
        let server = HTTPServer { _ in .text("hello") }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let first = try await rawResponse(port: port, request: request())
        let strongTag = etag(from: first)!
        let weakTag = "W/" + strongTag
        let response = try await rawResponse(
            port: port,
            request: request("If-None-Match: \(weakTag)\r\n")
        )
        #expect(response.hasPrefix("HTTP/1.1 304 Not Modified"))
    }

    @Test func etagListWithMatchReturns304() async throws {
        let server = HTTPServer { _ in .text("hello") }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let first = try await rawResponse(port: port, request: request())
        let tag = etag(from: first)!
        let response = try await rawResponse(
            port: port,
            request: request("If-None-Match: \"other\", \(tag)\r\n")
        )
        #expect(response.hasPrefix("HTTP/1.1 304 Not Modified"))
    }

    @Test func ifModifiedSinceHitReturns304() async throws {
        let modified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, headers: ["last-modified": modified], body: Data("hello".utf8))
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: request("If-Modified-Since: Thu, 22 Oct 2015 07:28:00 GMT\r\n")
        )
        #expect(response.hasPrefix("HTTP/1.1 304 Not Modified"))
    }

    @Test func ifModifiedSinceMissReturns200() async throws {
        let modified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, headers: ["last-modified": modified], body: Data("hello".utf8))
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(
            port: port,
            request: request("If-Modified-Since: Tue, 20 Oct 2015 07:28:00 GMT\r\n")
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func ifNoneMatchTakesPrecedenceOverIfModifiedSince() async throws {
        let modified = "Wed, 21 Oct 2015 07:28:00 GMT"
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, headers: ["last-modified": modified], body: Data("hello".utf8))
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }

        // If-Modified-Since 命中会返回 304，但 If-None-Match 不匹配应优先返回 200
        let response = try await rawResponse(
            port: port,
            request: request(
                "If-None-Match: \"nope\"\r\nIf-Modified-Since: Thu, 22 Oct 2015 07:28:00 GMT\r\n"
            )
        )
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func nonGetHeadMethodSkipsConditional() async throws {
        let server = HTTPServer { _ in .text("posted") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port, request: request("If-None-Match: *\r\n", method: "POST"))
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
    }

    @Test func handlerProvidedETagIsPreserved() async throws {
        let server = HTTPServer { _ in
            HTTPResponse(status: .ok, headers: ["etag": "\"custom-123\""], body: Data("hello".utf8))
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port, request: request())
        #expect(etag(from: response) == "\"custom-123\"")
    }

    @Test func differentBodiesProduceDifferentETags() async throws {
        let server = HTTPServer { req in .text(req.target == "/a" ? "aaa" : "bbb") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let a = try await rawResponse(port: port, request: request().replacingOccurrences(of: "GET / ", with: "GET /a "))
        let b = try await rawResponse(port: port, request: request().replacingOccurrences(of: "GET / ", with: "GET /b "))
        #expect(etag(from: a) != etag(from: b))
    }
}
