//
//  ResponseContractTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

struct ResponseContractTests {
    // MARK: - P0 response semantics

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
}
