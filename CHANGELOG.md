# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- JSON bodies use [json.zig](https://github.com/lalinsky/json.zig) instead of `std.json`, and MessagePack bodies are supported through [msgpack.zig](https://github.com/lalinsky/msgpack.zig) with `Request.msgpack` and `Response.msgpack`. `ClientResponse.json` and `ClientResponse.msgpack` decode a client response body the same way. `Response.json` now leaves out null optional fields, types shape their encoding with json.zig's `jsonFormat`/`jsonWrite` instead of `jsonStringify`, and `Request.jsonValue` and `Request.jsonObject` are removed. Build with `-Duse_json=false` or `-Duse_msgpack=false` to leave either out.
- `Response.writer()` writes the body in place into segments of the request arena, instead of passing every write through the body writer's vtable into a growing buffer. Handlers that encode JSON bodies of a few KB are about twice as fast.
- `Response.writeHeader` is no longer public. Use `Response.stream` to send the headers before the body.
- `Listener.acceptors` now defaults to null, which picks log2 of the CPUs the process may use (honoring cgroup CPU quotas), and at least two, instead of a fixed two.

## [0.3.1] - 2026-09-21

- Added whole-request HTTP client deadlines. `ClientConfig.timeout` defaults to 30 seconds, and `FetchOptions.timeout` can replace or disable it for an individual request. Buffered response bodies remain covered through completion; explicitly streamed responses are left to the caller.
- Added trusted reverse-proxy hop handling to the HTTP server. Configure `ServerConfig.trusted_proxy_hops` to resolve `Request.remote_address` safely from the right side of `X-Forwarded-For`; direct peers remain the default and malformed or incomplete chains fall back to them.
- Re-exported `BodyWriter` and `StreamingBodyWriter` from the root module so callers can name the concrete types returned by `Response.writer` and `Response.stream`.
- Added the Dusty httpbin container image and release-tagged publishing workflow.
- Added timeout and buffered-response controls to the HTTP client example.

## [0.3.0] - 2026-09-20

This is a substantial release focused on making Dusty runtime-independent, safer under load, and more predictable at HTTP protocol boundaries.

### Highlights

- Dusty now targets Zig's `std.Io` interface directly and no longer has a hard dependency on `zio`. It works with `std.Io.Threaded`, zio, and other `std.Io` implementations; zio remains the recommended backend for highly concurrent servers and gets native deadline cancellation when explicitly injected.
- TLS is now configurable on both sides of a connection. The server can serve HTTPS, and the client and server both support mutual TLS, system or custom CA stores, and certificate verification controls. TLS can be compiled out with `-Duse_tls=false`.
- Server operation is bounded by default: at most 10,000 open connections, a 30-second request timeout, a 60-second keep-alive timeout, and a 30-second graceful-shutdown budget. Handlers can replace or disable their current deadline with `Request.setTimeout`.
- Request and response bodies can be processed as streams. Transparent gzip/deflate decoding now applies while streaming client responses and, by default, incoming server requests. Response streaming has explicit buffered and streaming writers with reliable framing and error reporting.

### HTTP client

- Added a configurable default `User-Agent` and first-class TLS configuration, including custom trust roots, client certificates, and an explicit insecure mode for testing.
- Made the connection pool safe to share across concurrent tasks, and fixed stale, unread, failed, or redirecting connections being returned to the pool.
- Redirect handling now follows only redirect statuses, applies the expected method changes, strips credentials when crossing origins or downgrading to HTTP, sets `Referer`, and reuses connections when the previous response can be drained safely.
- Improved interoperability for IPv6 literal URLs, interim `1xx` responses, `HEAD` responses, bodyless `POST`/`PUT`/`PATCH` requests, and responses delimited by connection close.
- Client response headers are bounded, duplicate header fields are preserved, and truncated or malformed bodies now return specific errors instead of generic I/O failures.

### HTTP server and application API

- Added server-side TLS and optional/required client-certificate authentication, with TLS handshakes covered by the request timeout.
- Added transparent request-body decompression, caller-buffered body readers, typed path/query parameter lookups, request peer addresses, cookie iteration, and JSON serialization for headers, parameters, and cookies.
- Reworked response writing so buffered, fixed-length, chunked, HTTP/1.0, `HEAD`, and bodyless-status responses are framed consistently. Server-Sent Events now support multi-line and incrementally produced event data.
- Header names, values, cookies, multipart fields, body lengths, and message heads receive stricter validation. Oversized request heads receive `431`, malformed query strings receive `400`, and handler failures produce error responses without leaking partial bodies.
- Graceful shutdown now waits only for in-flight requests rather than idle keep-alive connections, and connection/request limits are enforced without busy-waiting.

### WebSocket and reliability

- WebSocket sends are serialized so concurrent tasks cannot interleave frames. Incoming frames now enforce masking, fragmentation, close-code, UTF-8, opcode, and control-frame rules and reply with the appropriate protocol close.
- WebSocket message storage is reclaimed between receives, fixing growth over long-lived connections.
- Error propagation across plain sockets, TLS, response streams, SSE, and WebSockets now preserves the underlying transport error. Numerous cleanup paths were tightened to prevent leaks and double releases after failed connects, TLS handshakes, redirects, spawns, and disconnects.

### Upgrade notes

- Server addresses and networking types now use `std.Io`; `Server.listen` accepts `dusty.Address`. Applications using zio should explicitly inject its module into Dusty to enable zio-native timeout cancellation.
- `ServerConfig.timeout.request` and `.keepalive` now take `std.Io.Duration` instead of millisecond integers and are finite by default. A new `.shutdown` timeout and `max_connections` limit are also enabled by default; set them to `null` to remove those bounds.
- `ClientConfig.use_system_ca_bundle` was replaced by `ClientConfig.tls`; the equivalent setting is `.tls = .{ .ca = .system }` (also the new default).
- `Request.reader` and `ClientResponse.reader` now take a caller-owned buffer and can fail during setup. `Response.writer`, `Response.stream`, and event writers return explicit writer objects whose `end` method must be called; `startEventStream` now also takes a buffer.
- `Headers` is now a bounded, case-insensitive, multi-value collection. Use `add` to preserve repeated fields and access iterator entries through `.key` and `.value`. Request path and query values now use `Params`, which adds typed numeric lookups.

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

[Unreleased]: https://github.com/lalinsky/dusty/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/lalinsky/dusty/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/lalinsky/dusty/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/lalinsky/dusty/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lalinsky/dusty/releases/tag/v0.1.0
