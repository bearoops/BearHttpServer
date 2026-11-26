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

The current implementation supports HTTP/1.0 and HTTP/1.1 requests with
`Content-Length` bodies, keep-alive connections, and `HEAD` responses without a
body. Chunked request bodies are rejected with `501 Not Implemented`.

## Topics

### Servers

- ``HTTPServer``
- ``HTTPServerConfiguration``
- ``HTTPServerError``

### HTTP

- ``HTTPRequest``
- ``HTTPResponse``
- ``HTTPHeaders``
- ``HTTPMethod``
- ``HTTPStatusCode``
- ``HTTPVersion``
