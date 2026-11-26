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

The current implementation supports HTTP/1.0 and HTTP/1.1 requests with
`Content-Length` bodies, keep-alive connections, and `HEAD` responses without a
body. Responses use the same HTTP version as the request: an HTTP/1.0 client
receives an `HTTP/1.0` status line. Chunked request bodies are rejected with
`501 Not Implemented`.

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
- `HTTPServerConfiguration` — host, port, size limits and idle timeout.
- `HTTPServerError` — errors thrown while starting the server.

### HTTP types

- `HTTPRequest` / `HTTPResponse` — the values passed to and returned from a handler.
- `HTTPHeaders` — case-insensitive header storage.
- `HTTPMethod` / `HTTPVersion` / `HTTPStatusCode` — request and response metadata.

Each public type also has inline documentation available via Xcode's Quick Help.

## License

BearHttpServer is available under the MIT license. See [LICENSE](LICENSE).
Release notes are tracked in [CHANGELOG.md](CHANGELOG.md).
