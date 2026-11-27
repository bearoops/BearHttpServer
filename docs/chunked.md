# Chunked 传输编码说明

本文解释 BearHttpServer 中 `Transfer-Encoding: chunked` 的实现，以及测试中几个容易困惑的点。对应代码在 `BearHttpServer/HTTPConnection.swift`，测试在 `BearHttpServerTests/BearHttpServerTests.swift`。

## 为什么需要 chunked

普通响应用 `Content-Length` 声明 body 长度，客户端按字节数读取。但如果长度在发送前无法确定（流式生成、动态压缩、大文件），就不能用 `Content-Length`。HTTP/1.1 的 chunked 编码把 body 拆成一系列带长度前缀的块，最后用一个大小为 0 的块收尾，接收方不需要预先知道总长度。

服务端的行为：

- 请求端：`decodeChunkedBody`（`HTTPConnection.swift:485`）解码 chunked 请求体，支持 chunk 扩展与 trailer。
- 响应端：默认仍用 `Content-Length`；handler 在响应上设置 `transfer-encoding: chunked` 才会启用分块输出（`chunkedEncoded`，`HTTPConnection.swift:282`）。

## 编码格式

一个 chunk 的 framing 是：

```
<size 十六进制><可选扩展>\r\n
<size 字节数据>\r\n
```

整个 body：

```
5;ext=value\r\n        ← size = 0x5 = 5 字节，附带一个扩展
hello\r\n              ← 5 字节数据 + CRLF
E\r\n                  ← size = 0xE = 14 字节
 chunked world\r\n     ← 14 字节数据 + CRLF
0\r\n                  ← last-chunk，size = 0
X-Checksum: abc\r\n    ← trailer 字段（可选）
\r\n                   ← 空行，trailer section 结束
```

## 常见问题

### 为什么响应末尾要加 `0`

`0` 是 **last-chunk**，不是数据。chunked 没有 `Content-Length`，客户端靠一个 size 为 0 的块判断 body 结束。没有它，客户端读完最后一个数据块后会继续等下一个 size 行，一直挂到连接关闭。

`0\r\n\r\n` 拆开是 `0\r\n`（size 为 0 的块）+ `\r\n`（空 trailer 区块结束行）。所以测试断言：

```swift
#expect(raw.hasSuffix("3\r\nabc\r\n0\r\n\r\n"))
```

其中 `3\r\nabc\r\n` 是唯一的那个数据块，`0\r\n\r\n` 是结束序列。

### `5;ext=value` 里的 `5` 是 5 个字节吗

是。`5` 是十六进制的 size，`0x5 = 5`。分号及其后的 `ext=value` 是 **chunk extension**——协议允许发送方附带元数据（如分块序号、校验值），接收方可以忽略，它不参与 size 计算。

解析时按分号切割只取第一段（`decodeChunkedBody`）：

```swift
line.split(separator: ";", maxSplits: 1).first  // "5"
Int("5", radix: 16)                              // 5
```

测试把这个 size 行拆成 `"5;ext"` 和 `"=value\r\n"` 两次 TCP 写入，是为了覆盖“framing 行只收到一半”的情况，不代表 size 改变了。

### 为什么 body 是 `"hello chunked world"` 而不是只有 `"hello"`

body 由**两个 chunk** 拼接而成。第一个 chunk 的 size 是 `5`，数据是 `hello`；第二个 chunk 的 size 是 `E`（十六进制 14），数据是 ` chunked world`（含前导空格，14 字符）。解析器依次追加每个 chunk 的数据：

```
"hello" + " chunked world" = "hello chunked world"
```

字节数吻合：`5 + 14 = 19`，而 `"hello chunked world"` 正好 19 个字符。用两个 chunk 是为了验证多块能被正确拼接，而不是只解析第一块。

### trailer section 有什么用

trailer 是 body 结束后可携带的额外 header 字段。它的价值在于：发送方流式生成 body 时，有些元数据（校验和、签名、总块数）要等 body 写完才能算出，无法放在开头的 header 里，就放到 trailer 里。

测试写入的 `"X-Checksum: abc\r\n\r\n"` 是：

- `X-Checksum: abc\r\n`：一个 trailer 字段行
- `\r\n`：空行，标志 trailer section 结束，也就是整个请求的结束边界

解析器必须逐行跳过 trailer 直到空行，才认为请求完整（`decodeChunkedBody` 中 `size == 0` 分支）。若处理有误，会把 trailer 误当作下一个请求的起始，或算错请求边界导致 keep-alive 错位。

当前实现只**消费并丢弃** trailer，不会把 `X-Checksum` 暴露到 `HTTPRequest.headers`。测试验证的是“能正确跳过并定位边界”，不是“能读到 trailer 值”。

## 测试为何分批发送

`chunkedRequestBodyIsDeliveredToHandler`（`BearHttpServerTests.swift:290`）刻意分 7 次 TCP 写入，而不是一次性发送整个请求。原因：一次性发送只测试“完整 buffer 的解析”，服务端不会进入 `.needMore` 分支；分批写入且每次间隔 20ms，才能覆盖数据分多次到达时的增量解析。首个 chunk 的 size 行也被拆成两次写，用于覆盖不完整的 framing 行。

该测试经过变异验证：临时让解析器在找不到 CRLF 时直接报错（而非返回 `.needMore`），测试即失败，证明它确实走到了增量解析路径。

## 相关测试

| 测试 | 覆盖点 |
| --- | --- |
| `chunkedRequestBodyIsDeliveredToHandler` | 多 chunk 拼接、chunk 扩展、trailer、增量解析 |
| `chunkedResponseUsesChunkedEncoding` | 响应分块输出格式、last-chunk |
| `invalidChunkSizeIsRejected` | 非法 size 返回 400 |
| `conflictingContentLengthAndChunkedIsRejected` | CL 与 TE 同时出现返回 400（防请求走私） |
| `oversizedChunkedBodyIsRejected` | 解码后 body 超过 `maxBodyBytes` 返回 413 |
