# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Remove hard dependency on `zio`, so you can use `dusty` with any `std.Io` implementation.
- There is still a special opt-in support for `zio`, because it's the only way to do proper timeouts on `std.Io` streams.
- Added TLS support to both the client and server.
- Fix memory leak in WebSocket clients: message allocations are now freed before each `receive()` call instead of accumulating for the lifetime of the connection.
- Added default `User-Agent` header to HTTP client.

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
