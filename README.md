# BearHttpServer

A lightweight HTTP/1.1 server for Apple platforms, built on Network.framework.

## Overview

`HTTPServer` uses `NWListener` and `NWConnection` to accept TCP connections and
dispatch parsed HTTP requests to an asynchronous handler. It binds to loopback
by default and can choose an available port automatically.

```swift
import BearHttpServer

let server = HTTPServer { request in
    HTTPResponse.text("Hello from \(request.target)")
}

let port = try await server.start()
// Serve requests at http://127.0.0.1:\(port)

// When finished:
await server.stop()
```

To bind a specific host or port:

```swift
let configuration = HTTPServerConfiguration(host: "0.0.0.0", port: 8080)
let server = HTTPServer(configuration: configuration) { request in
    HTTPResponse(status: .ok, body: Data("ok".utf8))
}
```

`HTTPServerConfiguration` also exposes `maxConnections` and
`connectionIdleTimeout` to bound resources; set the timeout to `0` to disable
idle closing. Pass `host: "::1"` to bind the IPv6 loopback instead.

### TLS / HTTPS

Set `tls` on the configuration to accept HTTPS. Provide a server identity
(certificate plus private key) directly or load one from a PKCS#12 bundle:

```swift
var configuration = HTTPServerConfiguration(host: "0.0.0.0", port: 8443)
configuration.tls = try HTTPServerTLSConfiguration(
    pkcs12: p12Data,
    password: "bundle-password"
)
let server = HTTPServer(configuration: configuration) { _ in
    HTTPResponse.text("secure")
}
```

When `tls` is `nil` (the default) the server serves plain HTTP. Only enable
plaintext on a trusted network; binding `0.0.0.0` without TLS exposes traffic
to anyone who can reach the port.

### Graceful shutdown

`await server.stop()` stops accepting new connections, closes idle ones
immediately, and lets in-flight requests finish. It waits up to
`gracefulShutdownTimeout` seconds (default 5) before cancelling whatever
remains; set it to `0` to close everything at once.

The current implementation supports HTTP/1.0 and HTTP/1.1 requests with
`Content-Length` or `Transfer-Encoding: chunked` bodies, keep-alive
connections, `Expect: 100-continue` handshakes, and `HEAD` responses without a
body. Responses use the same HTTP version as the request: an HTTP/1.0 client
receives an `HTTP/1.0` status line. Chunked request bodies are decoded (chunk
extensions and trailers are accepted); a handler can opt into chunked output
by setting `transfer-encoding: chunked` on its `HTTPResponse`, otherwise the
response uses `Content-Length`.

Conditional requests are supported for `GET`/`HEAD`: responses carry an
auto-generated `ETag` (override it by setting `etag` on the response), and
`If-None-Match` / `If-Modified-Since` produce a bodyless `304` when the client's
validator matches. To use `If-Modified-Since`, set `last-modified` on the
response — the core has no notion of a resource's modification time.

## Swift Package Manager

The repository includes a `Package.swift` using tools version 5.9, so the
library can be built and tested with SwiftPM on Xcode 15 or later:

```sh
swift build
swift test
```

To depend on a local checkout:

```swift
dependencies: [
    .package(path: "../BearHttpServer")
]
```

`swift build` and `swift test` may need `--disable-sandbox` in restricted
environments.

## Objective-C support

The framework installs `BearHttpServer-Swift.h` and exposes the `BR`-prefixed
classes for Objective-C clients:

```objc
#import <BearHttpServer/BearHttpServer-Swift.h>

BRHTTPServerConfiguration *configuration = [[BRHTTPServerConfiguration alloc] init];
configuration.port = 8080;
configuration.maxConnections = 64;          // defaults to 128
configuration.connectionIdleTimeout = 30;   // defaults to 60; 0 disables

BRHTTPServer *server = [[BRHTTPServer alloc]
    initWithConfiguration:configuration
           requestHandler:^(BRHTTPRequest *request,
                            void (^completion)(BRHTTPResponse *response)) {
               BRHTTPResponse *response =
                   [BRHTTPResponse textResponseWithString:@"Hello" statusCode:200];
               completion(response);
           }];

[server startWithCompletion:^(NSInteger port, NSError *error) {
    if (!error) {
        NSLog(@"http://127.0.0.1:%ld", (long)port);
    }
}];

// Later:
[server stopWithCompletion:^{
}];
```

Objective-C handlers should call the response completion exactly once for each
request. Extra calls are ignored; if a handler never calls it, the request is
answered with HTTP 504 after `handlerTimeout` seconds (default 30, configurable
on `BRHTTPServerConfiguration`). Start/stop completion blocks are invoked on the
main queue; request handlers may run on any thread.

Response reason phrases and header values are sanitized: CR/LF characters are
replaced with spaces so untrusted values cannot inject extra header lines.
Statuses that cannot carry a body (`1xx`, `204`, `304`) omit `Content-Length`
and the body; `HEAD` keeps `Content-Length` but sends no body.

## API overview

### Server

- `HTTPServer` — the actor that accepts connections and dispatches requests.
- `HTTPServerConfiguration` — host, port, size limits, idle timeout, TLS and
  graceful-shutdown settings.
- `HTTPServerTLSConfiguration` — server identity for HTTPS, from a `SecIdentity`
  or a PKCS#12 bundle.
- `HTTPServerError` — errors thrown while starting the server.

### HTTP types

- `HTTPRequest` / `HTTPResponse` — the values passed to and returned from a handler.
- `HTTPHeaders` — case-insensitive header storage.
- `HTTPMethod` / `HTTPVersion` / `HTTPStatusCode` — request and response metadata.

Each public type also has inline documentation available via Xcode's Quick Help.

## Optional routing (`BearHttpServerRouting`)

The core library stays a zero-dependency HTTP/1.1 engine. A separate product adds
lightweight routing and request parsing without modifying `HTTPRequest`:

```swift
import BearHttpServer
import BearHttpServerRouting

var router = Router()
router.on(.get, "/users/:id") { request, params in
    let id = params["id"] ?? ""
    return .text("user \(id), q=\(request.query("q") ?? "")")
}
let server = HTTPServer(handler: router.handler())
```

- Patterns match path segments: `:name` captures one segment, `*` matches one
  arbitrary segment. Registration order decides precedence.
- Handlers receive `(HTTPRequest, RouteParams)` so path parameters never get
  injected into the core request type.
- Unmatched path → 404; path matched but wrong method → 405 with an `Allow` header.
- `HTTPRequest` gains `path`, `query`, `queryItems`, `query(_:)`, `cookies` and
  `cookie(_:)`. Malformed percent escapes are preserved rather than trapping.
- See [routing plan](docs/routing-plan.md) for design notes and scope.

## Documentation

- [Chunked transfer encoding](docs/chunked.md) — how chunked request/response
  bodies are encoded and decoded, and what the related tests cover.
- [Routing plan](docs/routing-plan.md) — design and implementation notes for
  the optional routing extension.

## License

BearHttpServer is available under the MIT license. See [LICENSE](LICENSE).
Release notes are tracked in [CHANGELOG.md](CHANGELOG.md).
