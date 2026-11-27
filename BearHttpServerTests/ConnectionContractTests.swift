//
//  ConnectionContractTests.swift
//  BearHttpServerTests
//

import Foundation
import Network
import Testing
@testable import BearHttpServer

struct ConnectionContractTests {
    // MARK: - P0 connection limits and P1 handler timeout

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

    // MARK: - 守约测试（P1：Swift handler 超时）

    @Test func handlerTimeoutReturns504() async throws {
        var configuration = HTTPServerConfiguration.localhost
        configuration.handlerTimeout = 0.3
        let gate = Signal()
        let server = HTTPServer(configuration: configuration) { _ in
            await gate.wait()   // 挂起，直到测试结束时释放
            return HTTPResponse.text("too late")
        }
        let port = try await server.start()
        defer {
            Task { await gate.fire() }
            Task { await server.stop() }
        }
        let response = try await rawResponse(
            port: port,
            request: "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        #expect(response.hasPrefix("HTTP/1.1 504 Gateway Timeout"))
        #expect(response.contains("Request handler timed out."))
    }

    @Test func fastHandlerIsNotAffectedByTimeout() async throws {
        var configuration = HTTPServerConfiguration.localhost
        configuration.handlerTimeout = 5
        let server = HTTPServer(configuration: configuration) { _ in .text("fast") }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("fast"))
    }

    @Test func zeroHandlerTimeoutDisablesTimeout() async throws {
        var configuration = HTTPServerConfiguration.localhost
        configuration.handlerTimeout = 0
        let gate = Signal()
        let server = HTTPServer(configuration: configuration) { _ in
            try? await Task.sleep(nanoseconds: 100 * 1_000_000)
            await gate.fire()
            return HTTPResponse.text("done")
        }
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let response = try await rawResponse(port: port)
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("done"))
    }

    @Test func timeoutDoesNotLeakAcrossConcurrentRequests() async throws {
        var configuration = HTTPServerConfiguration.localhost
        configuration.handlerTimeout = 0.3
        let releaseSlow = Signal()
        let server = HTTPServer(configuration: configuration) { request in
            if request.target == "/slow" {
                await releaseSlow.wait()
            }
            return .text("ok-\(request.target)")
        }
        let port = try await server.start()
        defer {
            Task { await releaseSlow.fire() }
            Task { await server.stop() }
        }
        // 慢请求（会超时）与快请求并发
        async let slow = rawResponse(
            port: port,
            request: "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        async let fast = rawResponse(
            port: port,
            request: "GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )
        let (slowResponse, fastResponse) = try await (slow, fast)
        #expect(slowResponse.hasPrefix("HTTP/1.1 504"))
        #expect(fastResponse.hasPrefix("HTTP/1.1 200"))
        #expect(fastResponse.contains("ok-/fast"))
    }

    // MARK: - P1：ObjC 配置透传

    @Test func objcConfigurationDefaultsMatchSwift() {
        let configuration = ObjCHTTPServerConfiguration()
        #expect(configuration.maxConnections == 128)
        #expect(configuration.connectionIdleTimeout == 60)
    }

    @Test func objcConfigurationPushesMaxConnectionsToServer() async throws {
        let configuration = ObjCHTTPServerConfiguration()
        configuration.maxConnections = 1
        let server = ObjCHTTPServer(configuration: configuration) { _, completion in
            completion(ObjCHTTPResponse.text("ok", statusCode: 200))
        }
        let port = try await startObjCServer(server)
        defer { Task { await stopObjCServer(server) } }

        // 第一条连接占住唯一名额
        let first = makeRawConnection(port: port)
        defer { first.cancel() }
        try await sendRaw("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", on: first)
        _ = try await receiveRaw(from: first)

        // 第二条连接不应得到响应
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
                if oneShot.claim() { c.resume(returning: false) }
            }
        }
        #expect(!responded)
    }
}
