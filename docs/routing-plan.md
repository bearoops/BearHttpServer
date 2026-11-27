# 轻量路由与解析辅助 · 实施方案

> 本文从 `comparison-and-roadmap.md` 拆出，对应投入优先级清单第 1 项（P0）。
> 分析基准：2026-11-27，基于源码现状。

## 目标与约束

**目标**：让调用方不再自己拆 `request.target`、手写 query / Cookie 解析；不改动 HTTP 内核，以独立 extension 交付。

**现状约束**（来自源码）：
- `HTTPRequest` 只有 `method` / `target: String` / `version` / `headers` / `body`（HTTPTypes.swift:147-155），`target` 是原始字符串。
- `HTTPHeaders` 提供 `all: [String: String]`（大小写归一后的字典），Cookie 可直接从中取。
- `HTTPServer` 只接受一个 `@Sendable (HTTPRequest) async throws -> HTTPResponse`（HTTPServer.swift:61）——路由必须以「单 handler 内的分发器」形态接入，不改内核签名。

**交付形态**：新增独立 target `BearHttpServerRouting`，保留主库为零依赖内核。

```
Package.swift 新增：
  .library(name: "BearHttpServerRouting", targets: ["BearHttpServerRouting"]),
  .target(name: "BearHttpServerRouting", dependencies: ["BearHttpServer"]),
  .testTarget(name: "BearHttpServerRoutingTests", dependencies: ["BearHttpServerRouting"]),

新文件：
  BearHttpServerRouting/Router.swift           — 路由表 + 分发 handler
  BearHttpServerRouting/RequestParsing.swift   — query / Cookie / 路径参数解析
  BearHttpServerRoutingTests/RouterTests.swift
```

**API 草案**：

```swift
// 1) 解析辅助（纯函数，值类型，Sendable）
extension HTTPRequest {
    public var path: String                  // target 去掉 ?query，百分号解码
    public var queryItems: [URLQueryItem]    // 按 & 拆分，+ 转空格，百分号解码
    public func query(_ name: String) -> String?
    public var cookies: [String: String]     // 解析 Cookie 头，重复键后者覆盖
    public func cookie(_ name: String) -> String?
}

// 2) 路由表
public struct Router: Sendable {
    public init()
    public mutating func on(_ method: HTTPMethod,
                            _ pattern: String,       // "/users/:id"
                            handler: @Sendable @escaping (HTTPRequest) async throws -> HTTPResponse)
    public func handler() -> @Sendable (HTTPRequest) async throws -> HTTPResponse
}

// 用法：
var router = Router()
router.on(.GET, "/users/:id") { req in
    let id = req.pathParameters["id"] ?? ""
    return .text("user \(id)")
}
let server = HTTPServer(handler: router.handler())
```

**实现要点**：
- 路径匹配自己做，不引入 Foundation 以外依赖：按 `/` 分段，`:name` 捕获一段，先精确后模式，注册顺序定优先级。
- 百分号解码遇畸形序列（非法 `%`）保留原样而非崩溃；query 中 `+` 按表单语义转空格。
- Cookie 用 `;` 分隔、`=` 拆分，值去引号。
- 全为值类型 + `@Sendable` 闭包，天然满足 Swift 6 严格并发；路由表构建后不可变，无共享可变状态。

**已定决策**：`pathParameters` 通过方案 A 传递——路由 handler 签名为
`(HTTPRequest, RouteParams)`，路径参数放进新的 `RouteParams` 值类型，**不碰内核的 `HTTPRequest`**，
符合"独立 extension、零侵入内核"的定位。（方案 B「给 HTTPRequest 加内部 init 注入参数」已弃用。）

**方法不匹配策略**：定为 405，并带 `Allow` 头列出该路径已注册的所有方法；路径完全不匹配返回 404。

**分阶段步骤**：

| 阶段 | 内容 | 验证 |
|---|---|---|
| S1 | `RequestParsing.swift`：path / query / cookies 纯函数 + 单测 | 覆盖编码、畸形 `%`、`+`、重复 Cookie、大小写 |
| S2 | `Router.swift`：精确匹配 + `:param` 捕获 + 方法匹配 + 404 兜底 + 单测 | 覆盖未命中、方法不符、参数解析、多路由优先级 |
| S3 | 端到端：起 `HTTPServer(handler: router.handler())`，用 `URLSession` 打真实请求 | 验证与内核集成、并发请求不串路由 |
| S4 | README 增补用法 + CHANGELOG 记录 | 文档与代码同步 |

**实施结果（2026-11-27）**：S1~S4 均完成。`swift test --disable-sandbox` 全绿——
新增 13 项解析测试 + 14 项路由单测 + 5 项真实 socket 端到端测试，
加上原有 27 项，共 **59 项测试**。端到端覆盖了 query/Cookie 解析、路径参数、
404、以及 10 并发请求不串路由。

**测试计划**（已落实）：解析边界（空 query、无 `=` 参数、`%ZZ` 非法编码）、路径参数（中文/编码值）、方法不匹配→405、默认 404、并发请求路由不串，均已有对应测试。

**实际工作量**：约 450 行（解析 ~100、路由 ~110、测试 ~240），略高于"200~400 行"的原估，主要来自真实 socket 端到端测试。`pathParameters` 传递方式已按方案 A 落地，内核零侵入。

**明确不做**：正则路由、中间件链、依赖注入、静态文件挂载——会把"轻量 extension"拖成"Web 框架"，与内核定位冲突。
