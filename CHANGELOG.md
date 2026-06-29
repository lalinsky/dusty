# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Optional HTTP/2 client support, gated behind the `use_http2` build option and the `http2` client config flag. Built on the bundled nghttp2 library and negotiated over TLS ALPN; multiplexes concurrent requests over a single connection per origin, with HTTP/1.1 fallback, redirects, and gzip/deflate decompression. Response bodies stream incrementally with flow-control backpressure.
- Fix memory leak in WebSocket clients: message allocations are now freed before each `receive()` call instead of accumulating for the lifetime of the connection. Message data is valid until the next call to `receive()`.

## [0.2.0] - 2026-04-26

- Support for Zig 0.16, still depends on zio, not using `std.Io` due to lack of timeout support.
- Fix flushing in websocket client when using it over HTTPS.
- Added support for 100-continue in the HTTP client.

## [0.1.0] - 2026-03-02

Initial release.

### Features

- HTTP/1.0 and HTTP/1.1 server with router, parameters, and wildcards.
- HTTP/HTTPS client with connection pooling and DNS resolution.
- Unix domain socket support for client connections.
- Chunked transfer encoding for request/response bodies.
- Server-Sent Events (SSE) support.
- WebSocket support (RFC 6455) for both client and server.
- Gzip/deflate decompression for HTTP client.
- Middleware system with CORS and session middleware.
- Cookie support.
- Request/keepalive timeouts via coroutine auto-cancellation.

[0.1.0]: https://github.com/lalinsky/dusty/releases/tag/v0.1.0
