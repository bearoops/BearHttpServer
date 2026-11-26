# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/bearoops/BearHttpServer/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bearoops/BearHttpServer/releases/tag/v0.1.0
