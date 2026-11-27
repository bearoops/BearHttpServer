//
//  Router.swift
//  BearHttpServerRouting
//

import Foundation
import BearHttpServer

/// 从路径中捕获的命名参数，如 `/users/:id` 的 `id`。
public struct RouteParams: Sendable {
    private let storage: [String: String]

    init(_ storage: [String: String] = [:]) {
        self.storage = storage
    }

    public subscript(name: String) -> String? { storage[name] }
    public var all: [String: String] { storage }
    public var count: Int { storage.count }
}

/// 路由 handler：比内核 handler 多一个 `RouteParams` 参数，
/// 这样路径参数无需塞进 `HTTPRequest`（内核类型保持零侵入）。
public typealias RouteHandler = @Sendable (HTTPRequest, RouteParams) async throws -> HTTPResponse

private struct Route: Sendable {
    let method: HTTPMethod
    let segments: [String]          // "/users/:id" → ["users", ":id"]
    let handler: RouteHandler

    /// 路径是否匹配；匹配时返回捕获的参数。
    func match(_ pathSegments: [String]) -> RouteParams? {
        guard segments.count == pathSegments.count else { return nil }
        var params: [String: String] = [:]
        for (pattern, actual) in zip(segments, pathSegments) {
            if pattern.hasPrefix(":") {
                let name = String(pattern.dropFirst())
                guard !name.isEmpty else { return nil }
                params[name] = percentDecode(actual, plusAsSpace: false)
            } else if pattern == "*" {
                continue // 简单通配符：匹配任意单段
            } else if pattern != actual {
                return nil
            }
        }
        return RouteParams(params)
    }
}

/// 轻量路由表。构建阶段用 `mutating on` 注册，完成后调用 `handler()`
/// 得到可直接交给 `HTTPServer` 的单 handler。
///
/// 匹配规则：
/// - 路径按 `/` 分段比较，`:name` 捕获一段，`*` 通配一段。
/// - 注册的路由按先后顺序匹配，先命中者胜出。
/// - 路径命中但方法不符返回 405（含 `Allow` 头），路径都不命中返回 404。
public struct Router: Sendable {
    private var routes: [Route] = []

    public init() {}

    /// 注册一条路由。`pattern` 形如 `/users/:id`。
    public mutating func on(
        _ method: HTTPMethod,
        _ pattern: String,
        handler: @escaping RouteHandler
    ) {
        let trimmed = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = trimmed.isEmpty ? [] : trimmed.split(separator: "/").map(String.init)
        routes.append(Route(method: method, segments: segments, handler: handler))
    }

    /// 便捷注册：任意方法（用空 rawValue 表示通配，HTTPMethod 初始化会转大写仍为空串）。
    public mutating func onAny(
        _ pattern: String,
        handler: @escaping RouteHandler
    ) {
        // 通配方法在 match 阶段用 rawValue.isEmpty 判定，不占用 HTTPMethod 常量
        routes.append(Route(
            method: HTTPMethod(rawValue: ""),
            segments: splitPath(pattern),
            handler: handler
        ))
    }

    /// 产出可交给 `HTTPServer(handler:)` 的分发闭包。
    public func handler() -> @Sendable (HTTPRequest) async throws -> HTTPResponse {
        { request in
            let path = request.path
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let segments = trimmed.isEmpty ? [] : trimmed.split(separator: "/").map(String.init)

            var allowed: [String] = []
            for route in routes {
                guard let params = route.match(segments) else { continue }
                if route.method.rawValue.isEmpty || route.method == request.method {
                    return try await route.handler(request, params)
                }
                if !allowed.contains(route.method.rawValue) {
                    allowed.append(route.method.rawValue)
                }
            }

            if !allowed.isEmpty {
                var headers = HTTPHeaders()
                headers["allow"] = allowed.joined(separator: ", ")
                return HTTPResponse(status: .methodNotAllowed, headers: headers)
            }
            return HTTPResponse(status: .notFound)
        }
    }

    private func splitPath(_ pattern: String) -> [String] {
        let trimmed = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? [] : trimmed.split(separator: "/").map(String.init)
    }
}
