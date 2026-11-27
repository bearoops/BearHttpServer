//
//  RouterTests.swift
//  BearHttpServerRoutingTests
//

import Testing
import Foundation
import BearHttpServer
@testable import BearHttpServerRouting

private func request(_ method: HTTPMethod, _ target: String) -> HTTPRequest {
    HTTPRequest(method: method, target: target)
}

@Suite struct RouterTests {
    @Test func exactMatch() async throws {
        var router = Router()
        router.on(.get, "/hello") { _, _ in .text("hi") }
        let r = try await router.handler()(request(.get, "/hello"))
        #expect(r.status == .ok)
        #expect(String(decoding: r.body, as: UTF8.self) == "hi")
    }

    @Test func unmatchedPathReturns404() async throws {
        var router = Router()
        router.on(.get, "/hello") { _, _ in .text("hi") }
        let r = try await router.handler()(request(.get, "/nope"))
        #expect(r.status == .notFound)
    }

    @Test func wrongMethodReturns405WithAllow() async throws {
        var router = Router()
        router.on(.get, "/hello") { _, _ in .text("hi") }
        let r = try await router.handler()(request(.post, "/hello"))
        #expect(r.status == .methodNotAllowed)
        #expect(r.headers["allow"] == "GET")
    }

    @Test func pathParametersCaptured() async throws {
        var router = Router()
        router.on(.get, "/users/:id") { _, params in
            .text(params["id"] ?? "none")
        }
        let r = try await router.handler()(request(.get, "/users/42"))
        #expect(String(decoding: r.body, as: UTF8.self) == "42")
    }

    @Test func pathParametersPercentDecoded() async throws {
        var router = Router()
        router.on(.get, "/users/:name") { _, params in
            .text(params["name"] ?? "none")
        }
        let r = try await router.handler()(request(.get, "/users/a%20b"))
        #expect(String(decoding: r.body, as: UTF8.self) == "a b")
    }

    @Test func multipleParameters() async throws {
        var router = Router()
        router.on(.get, "/users/:uid/posts/:pid") { _, params in
            .text("\((params["uid"] ?? "?"))-\((params["pid"] ?? "?"))")
        }
        let r = try await router.handler()(request(.get, "/users/7/posts/99"))
        #expect(String(decoding: r.body, as: UTF8.self) == "7-99")
    }

    @Test func wildcardMatchesSingleSegment() async throws {
        var router = Router()
        router.on(.get, "/files/*/view") { _, _ in .text("ok") }
        let hit = try await router.handler()(request(.get, "/files/abc/view"))
        #expect(hit.status == .ok)
        let miss = try await router.handler()(request(.get, "/files/a/b/view"))
        #expect(miss.status == .notFound)
    }

    @Test func registrationOrderWins() async throws {
        var router = Router()
        router.on(.get, "/x/:id") { _, _ in .text("first") }
        router.on(.get, "/x/special") { _, _ in .text("second") }
        let r = try await router.handler()(request(.get, "/x/special"))
        #expect(String(decoding: r.body, as: UTF8.self) == "first")
    }

    @Test func queryIsIgnoredInMatching() async throws {
        var router = Router()
        router.on(.get, "/search") { req, _ in
            .text(req.query("q") ?? "none")
        }
        let r = try await router.handler()(request(.get, "/search?q=swift"))
        #expect(String(decoding: r.body, as: UTF8.self) == "swift")
    }

    @Test func methodMismatchAllowCollectsAll() async throws {
        var router = Router()
        router.on(.get, "/r") { _, _ in .text("g") }
        router.on(.put, "/r") { _, _ in .text("p") }
        let r = try await router.handler()(request(.post, "/r"))
        #expect(r.status == .methodNotAllowed)
        #expect(r.headers["allow"] == "GET, PUT")
    }

    @Test func anyMethodRoute() async throws {
        var router = Router()
        router.onAny("/any") { _, _ in .text("any") }
        let g = try await router.handler()(request(.get, "/any"))
        let p = try await router.handler()(request(.post, "/any"))
        #expect(g.status == .ok)
        #expect(p.status == .ok)
    }

    @Test func thrownErrorPropagates() async throws {
        struct Boom: Error {}
        var router = Router()
        router.on(.get, "/boom") { _, _ in throw Boom() }
        await #expect(throws: Boom.self) {
            _ = try await router.handler()(request(.get, "/boom"))
        }
    }

    @Test func rootPath() async throws {
        var router = Router()
        router.on(.get, "/") { _, _ in .text("root") }
        let r = try await router.handler()(request(.get, "/"))
        #expect(String(decoding: r.body, as: UTF8.self) == "root")
    }

    @Test func concurrentRequestsDoNotCrossRoutes() async throws {
        var router = Router()
        router.on(.get, "/a/:id") { _, params in .text("a-\((params["id"] ?? "?"))") }
        router.on(.get, "/b/:id") { _, params in .text("b-\((params["id"] ?? "?"))") }
        let h = router.handler()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let target = i % 2 == 0 ? "/a/\(i)" : "/b/\(i)"
                    let resp = try await h(request(.get, target))
                    return String(decoding: resp.body, as: UTF8.self)
                }
            }
            var out: [String] = []
            for try await r in group { out.append(r) }
            return out
        }
        for i in 0..<20 {
            let expected = i % 2 == 0 ? "a-\(i)" : "b-\(i)"
            #expect(results.contains(expected))
        }
    }
}
