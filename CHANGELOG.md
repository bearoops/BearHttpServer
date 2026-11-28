# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Replaced all `NSLock` usage in tests with actors (`OnceFlag`, `LockedData`,
  `LockedFlag`, `LockedCounter`, `LockedStrings`) for a uniform Swift
  Concurrency model. No production code was affected.

## [0.4.0] - 2026-11-28

### Added

- Configurable `HTTPServerConfiguration.handlerTimeout` for Swift async
  handlers. A timed-out handler receives a 504 response (matching the ObjC
  bridge's fallback); default `0` disables the timeout.
- Exposed `maxConnections` and `connectionIdleTimeout` on
  `BRHTTPServerConfiguration` so Objective-C callers can use the core resource
  limits (defaults 128 and 60, matching Swift).
- Conditional requests: `GET`/`HEAD` responses carry an auto-generated `ETag`
  (FNV-1a of the body, overridable via the `etag` response header).
  `If-None-Match` (`*`, lists, weak `W/` tags) and `If-Modified-Since` (when the
  handler sets `last-modified`) return a bodyless 304 on a match. New
  `HTTPStatusCode.notModified` (304).
- Streaming bodies: `HTTPServer(streamingHandler:)` with `RequestBodyStream`
  reads request bodies chunk by chunk (total still bounded by `maxBodyBytes`);
  `HTTPResponse.bodyStream` produces response chunks with back-pressure.
  Streaming requests reject chunked framing (501); HTTP/1.0 streaming responses
  collect into a Content-Length body. Standard handler API unchanged.

## [0.3.0] - 2026-11-27

### Added

- New optional product `BearHttpServerRouting`: a lightweight `Router` with
  path-segment matching (`:param`, `*`), method dispatch (404 / 405 with
  `Allow`), and `HTTPRequest` parsing helpers (`path`, `query`, `queryItems`,
  `cookies`). Handlers receive `(HTTPRequest, RouteParams)` so the core request
  type stays untouched.
- Six regression tests for response and connection semantics: HEAD keeps
  `Content-Length` with no body, RFC 1123 `Date` format, default 404 handler,
  duplicate `Content-Length` rejected with 400, `maxConnections` limit, and
  idle-timeout connection closure.

## [0.2.0] - 2026-11-27

### Added

- TLS/HTTPS support via `HTTPServerConfiguration.tls` and the new
  `HTTPServerTLSConfiguration` (accepts a `SecIdentity` or a PKCS#12 bundle).
- Graceful shutdown: `stop()` now drains in-flight requests up to
  `gracefulShutdownTimeout` (default 5s, `0` closes immediately) before
  cancelling connections.
- `Expect: 100-continue` support: the server sends an interim `100 Continue`
  before reading a body, and rejects oversized requests with a final status
  instead of granting the expectation.
- Chunked request bodies (`Transfer-Encoding: chunked`) are decoded, including
  chunk extensions and trailers. Chunked responses are available by setting
  `transfer-encoding: chunked` on the response.

### Fixed

- Reject requests that advertise both `Content-Length` and
  `Transfer-Encoding` with `400 Bad Request` to avoid request smuggling.

### Changed

- Responses now echo the request's HTTP version; HTTP/1.0 requests receive an
  `HTTP/1.0` status line instead of `HTTP/1.1`.
- Reuse a single `DateFormatter` for the `Date` header instead of constructing
  one per response.
- Replaced all `NSLock` usage with actors: the shared date formatter, the idle
  timeout guard and the Objective-C one-shot completion are now serialized by
  Swift Concurrency. Timeouts use `Task.sleep` instead of `DispatchWorkItem`.
- Stop allowing local endpoint reuse so a bind conflict fails loudly rather
  than letting another socket silently share the port.

### Documentation

- Replace DocC symbol links in the README with plain Markdown API descriptions.

## [0.1.0] - 2026-11-26

### Added

- HTTP/1.0 and HTTP/1.1 server built on Network.framework (`NWListener` /
  `NWConnection`) with request routing, `Content-Length` bodies, keep-alive and
  `HEAD` support.
- Swift Concurrency based `HTTPServer` actor with async `start()` / `stop()`.
- Objective-C bridge with `BR`-prefixed classes and block-based callbacks.
- SwiftPM support and shared Xcode schemes.
- Connection limits (`maxConnections`) and idle timeout
  (`connectionIdleTimeout`) on `HTTPServerConfiguration`.
- IPv6 loopback support via `host: "::1"`.
- GitHub Actions CI, MIT license and changelog.

### Fixed

- Sanitize CR/LF in response reason phrases and header values to prevent
  response splitting.
- Omit `Content-Length` and body for `1xx`, `204` and `304` responses; keep
  `Content-Length` but no body for `HEAD`.
- Make the Objective-C bridge Swift 6 concurrency clean.
- Make Objective-C request completion one-shot with a configurable timeout and
  HTTP 504 fallback.
- Lower the SwiftPM tools version to 5.9 so Xcode 15 can consume the package.
- Report an Objective-C configuration error for out-of-range ports instead of
  silently clamping them.
- Actively close sockets when `Connection: close` is negotiated and release
  listener callback captures.

[Unreleased]: https://github.com/bearoops/BearHttpServer/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/bearoops/BearHttpServer/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bearoops/BearHttpServer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bearoops/BearHttpServer/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bearoops/BearHttpServer/releases/tag/v0.1.0
