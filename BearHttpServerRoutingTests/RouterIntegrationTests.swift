//
//  RouterIntegrationTests.swift
//  BearHttpServerRoutingTests
//

import Testing
import Foundation
import BearHttpServer
@testable import BearHttpServerRouting

/// S3：把 Router 接到真实 HTTPServer，用 URLSession 打真请求。
/// 验证分发闭包与内核的集成、query/Cookie 解析在真实链路上可用、并发不串路由。
@Suite struct RouterIntegrationTests {
    private func withServer(
        _ router: Router,
        _ body: (UInt16) async throws -> Void
    ) async throws {
        let server = HTTPServer(handler: router.handler())
        let port = try await server.start()
        defer { Task { await server.stop() } }
        try await body(port)
    }

    private func get(_ port: UInt16, _ path: String, cookies: [String: String] = [:])
        async throws -> (status: Int, body: String)
    {
        let url = URLComponents(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url.url!)
        if !cookies.isEmpty {
            let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1,
                String(decoding: data, as: UTF8.self))
    }

    @Test func routedRequestOverRealSocket() async throws {
        var router = Router()
        router.on(.get, "/hello") { _, _ in .text("hello") }
        try await withServer(router) { port in
            let result = try await get(port, "/hello")
            #expect(result.status == 200)
            #expect(result.body == "hello")
        }
    }

    @Test func pathParamsOverRealSocket() async throws {
        var router = Router()
        router.on(.get, "/users/:id") { _, params in .text(params["id"] ?? "none") }
        try await withServer(router) { port in
            let result = try await get(port, "/users/abc")
            #expect(result.status == 200)
            #expect(result.body == "abc")
        }
    }

    @Test func queryAndCookiesOverRealSocket() async throws {
        var router = Router()
        router.on(.get, "/api") { req, _ in
            .text("\((req.query("q") ?? "none"))|\((req.cookie("sid") ?? "none"))")
        }
        try await withServer(router) { port in
            let result = try await get(port, "/api?q=swift+server", cookies: ["sid": "S123"])
            #expect(result.status == 200)
            #expect(result.body == "swift server|S123")
        }
    }

    @Test func missingRouteReturns404OverRealSocket() async throws {
        var router = Router()
        router.on(.get, "/known") { _, _ in .text("ok") }
        try await withServer(router) { port in
            let result = try await get(port, "/missing")
            #expect(result.status == 404)
        }
    }

    @Test func concurrentRequestsKeepTheirOwnParams() async throws {
        var router = Router()
        router.on(.get, "/a/:id") { _, params in .text("a-\((params["id"] ?? "?"))") }
        router.on(.get, "/b/:id") { _, params in .text("b-\((params["id"] ?? "?"))") }
        try await withServer(router) { port in
            let results = try await withThrowingTaskGroup(of: String.self) { group in
                for i in 0..<10 {
                    group.addTask {
                        let path = i % 2 == 0 ? "/a/\(i)" : "/b/\(i)"
                        return (try await get(port, path)).body
                    }
                }
                var out: [String] = []
                for try await r in group { out.append(r) }
                return out
            }
            for i in 0..<10 {
                let expected = i % 2 == 0 ? "a-\(i)" : "b-\(i)"
                #expect(results.contains(expected))
            }
        }
    }
}
