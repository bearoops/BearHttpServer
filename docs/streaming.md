# 流式传输（Streaming Bodies）方案

本文解释 BearHttpServer 的请求 / 响应双侧流式传输：为什么需要、API 长什么样、
内核如何逐块搬运字节、背压是怎么形成的，以及明确的限制与边界。
对应代码在 `BearHttpServer/HTTPTypes.swift`、`HTTPServer.swift`、`HTTPConnection.swift`，
测试在 `BearHttpServerTests/StreamingBodyTests.swift`。

## 为什么需要流式

标准 handler 的签名是 `(HTTPRequest) async throws -> HTTPResponse`，`HTTPRequest.body`
和 `HTTPResponse.body` 都是完整 `Data`。这意味着内核必须把整个 body 攒在内存里才能
交给 handler，主体积受 `maxBodyBytes`（默认 16MB）约束。两个典型场景不适合这种模式：

- **大上传**：客户端在慢慢传一个几百 MB 的文件，服务端不可能等全部收完再处理，
  更不能把整个文件放进内存。
- **大下载 / 动态生成**：响应体是逐步产生的（导出报表、转码、代理转发），
  生成第一块时并不知道最终长度，也不该把所有块先拼成一个大 `Data`。

流式 API 让 body 以「块」为单位流动。内存里只保留正在处理的那一块，
而不是整个 body。注意这**不等于取消体积限制**——总量上限依然存在，
流式省的是「同时占用的内存」，不是「允许无限大的请求」。

## 两套 API，互不干扰

标准 API 保持原样，零侵入：

```swift
HTTPServer(handler: { request in
    // request.body 是完整 Data
    HTTPResponse.text("ok")
})
```

需要流式时，二选一或同时用：

```swift
// 请求侧：换成 streamingHandler
HTTPServer(streamingHandler: { request, body in
    var total = 0
    while let chunk = try await body.read() {   // nil 表示 body 结束
        total += chunk.count
    }
    return .text("received \(total) bytes")
})

// 响应侧：在任意 handler 里返回流式响应
HTTPServer { _ in
    HTTPResponse(status: .ok, bodyStream: {
        // 每次调用产生下一块；nil 表示结束
        generateNextChunk()
    })
}
```

关键类型：

| 类型 | 作用 |
| --- | --- |
| `RequestBodyStream` | actor，handler 用 `read()` 逐块取请求体 |
| `RequestBodyStreamError.payloadTooLarge` | 总量超过 `maxBodyBytes` 时 `read()` 抛出 |
| `HTTPServer.StreamingRequestHandler` | `(HTTPRequest, RequestBodyStream) async throws -> HTTPResponse` |
| `HTTPResponseBodyStream` | `@Sendable () async -> Data?`，逐块产出响应体 |
| `HTTPResponse.init(status:headers:bodyStream:)` | 构造流式响应 |

## 请求侧：边收边处理

实现位于 `HTTPConnection.runStreaming()`。一次请求的生命周期：

1. **先解析头部**（`parseStreamingHeader`），只拿到 method / target / headers 和 body
   帧格式（`Content-Length` 或 chunked），body 字节仍留在缓冲区里。头部同样受
   `maxHeaderBytes` 约束。
2. **建立 `RequestBodyStream`**，上限取 `configuration.maxBodyBytes`。
3. **先启动 handler task**。handler 里第一次 `read()` 会挂起等待——这是实现
   「边收边处理」的关键：不是收完 body 再调 handler，而是 handler 已经在跑、
   正等着数据。
4. **连接层逐块喂数据**：从缓冲区切出属于当前 body 的字节，调用 `stream.feed()`；
   喂给正在等待的 reader，或先入队。缓冲区空了就 `receive()` 再读一段。
5. body 收满后 `stream.finish()`，所有等待中的 reader 收到 `nil`，handler 读完并
   产出响应。
6. 发响应，回到循环处理该连接上的下一条请求（keep-alive）。

几个边界行为：

- **总量上限**：`feed()` 累计字节数，超过 `maxBodyBytes` 就把流置为失败状态，
  之后所有 `read()` 抛 `RequestBodyStreamError.payloadTooLarge`。这是「已读到的
  部分也算超限」，不是等到声明长度才判断。
- **截断的 body**：连接在 body 收完前关闭，`feedFailed` 为真，取消 handler task
  并回 `400 Bad Request`。
- **`Expect: 100-continue`**：头部解析后照常先发 `100 Continue`，再开始喂 body。
- **流式请求不支持 chunked 请求体**：chunked 帧格式无法在当前实现里增量喂给
  handler，带 `Transfer-Encoding: chunked` 的请求走流式 handler 会返回
  `501 Not Implemented`。需要 chunked 请求体时用标准 handler（标准路径仍完整
  支持 chunked 解码）。

**关于 TCP 分段**：一次 `sendRaw("hello ")` 加一次 `sendRaw("world")` 不保证 handler
会读到两块——TCP 可能把两次写合并成一个段，也可能拆成更多块。流式 API 只保证
「所有字节按顺序送达」，**不保留应用层的写边界**。测试也按这个语义断言完整数据，
而不是断言块数。

## 响应侧：边产边发

`send()` 检测到 `response.bodyStream != nil` 且当前响应允许携带 body 时，走流式发送：

- **HTTP/1.1**：自动设置 `transfer-encoding: chunked`、移除 `content-length`，
  然后先发头部，再循环：取一块 → 用 `chunkFrame()` 编码成 `<hex>\r\n<data>\r\n`
  → 发送 → 取下一块。所有块发完后补一个终止块 `0\r\n\r\n`。
- **HTTP/1.0**：协议不支持 chunked，无法在流开始时知道长度。内核先把整个流收集
  成 `Data`，再用 `Content-Length` 一次性发送。语义正确，但没有流式内存优势。
- **无 body 的响应**（1xx / 204 / 304）和 **HEAD 请求**：`statusAllowsBody` 或
  `includeBody` 为假，不消费 `bodyStream`，也不会发任何块。HEAD 的语义是
  「只给元信息、不给 body」。

注意 `chunkFrame()` 与旧的单块编码函数 `chunkedEncoded()` 的区别：后者自带终止块，
是为「一次性发完整 body」设计的；流式路径绝不能用它逐块编码，否则客户端会在
第一块之后看到 `0\r\n\r\n`、误以为响应已经结束。

## 背压是怎么形成的

背压来自发送循环的串行结构：

```
取下一块 → await 发送完成 → 再取下一块
```

`sendAll` 内部用 `contentProcessed` 回调 + continuation，只有内核确认这一块已经
交给网络层，循环才会继续向上游 `bodyStream` 要下一块。如果客户端读得慢，
`bodyStream` 就停在「等下一次调用」的状态，不会预生成一堆块堆在内存里。
这就是流式传输相对「先拼好整个 Data 再发」的核心优势。

需要注意：`bodyStream` 是同步拉取模型（每次调用产出一块），不是 push 模型。
如果单个 chunk 本身就很大，那块的体积仍由 handler 决定。

## 与条件请求 / ETag 的关系

`applyConditionalRequest()` 会对标准响应基于 body 计算 ETag（FNV-1a 哈希），
并处理 `If-None-Match` / `If-Modified-Since`。**流式响应跳过这一步**：它没有
物化的 body 可哈希，无法生成有意义的 ETag。所以给流式响应设置条件请求头不会
得到 304，响应会原样发出。如果确实需要缓存校验，请在普通 handler 里为具体
资源设置 `etag` / `last-modified`，并走标准响应路径。

## 测试覆盖

`StreamingBodyTests.swift` 共 9 项，覆盖：

- 请求侧：逐块读到完整数据；body 未收完时 handler 已读到第一块（证明边收边处理）；
  超过 `maxBodyBytes` 时 `read()` 抛错；chunked 请求体返回 501。
- 响应侧：多块 chunked 编码正确；块的拉取严格按「发完再取」顺序（背压）；
  URLSession 端到端解码出完整拼接结果；HEAD 无 body；HTTP/1.0 回退 Content-Length。

其中两个测试曾有典型的时序坑，记录如下，避免以后重蹈覆辙：

1. **不要断言块数**：TCP 会合并写入，两次写可能只产生一个 read。
2. **等流耗尽再断言**：客户端的 `receive()` 可能只拿到部分响应就返回，此时最后一次
   `pull`（返回 `nil`）还没发生。测试里用 `Signal` 在流耗尽时通知，再读取事件序列。

## 代码位置索引

| 内容 | 文件 / 符号 |
| --- | --- |
| 请求流类型与错误 | `HTTPTypes.swift` — `RequestBodyStream`, `RequestBodyStreamError` |
| 响应流类型 | `HTTPTypes.swift` — `HTTPResponseBodyStream`, `HTTPResponse.bodyStream` |
| 服务端入口 | `HTTPServer.swift` — `StreamingRequestHandler`, `init(streamingHandler:)` |
| 请求逐块处理 | `HTTPConnection.swift` — `runStreaming()`, `parseStreamingHeader()`, `RequestBodyStream.feed()` |
| 响应逐块发送 | `HTTPConnection.swift` — `send()`, `serializeHeaders()`, `chunkFrame()` |
| 测试 | `BearHttpServerTests/StreamingBodyTests.swift` |
