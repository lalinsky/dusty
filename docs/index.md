# Dusty

!!! warning "Draft"

    This page is a draft. Still to cover:

    - Build options: `use_tls`, `use_zlib`, and HTTP/2 through `use_http2` (off by default)
    - Supported Zig versions, and how 0.16 and 0.17 are both tested
    - Pointer to the examples directory

Dusty is an HTTP client and server library for Zig. It's built on the standard library's
[`std.Io`](https://ziglang.org/documentation/0.16.0/std/#std.Io) interface, and parses HTTP with
[llhttp](https://github.com/nodejs/llhttp), the parser from Node.js.

It runs on any `std.Io` implementation that supports networking, including `std.Io.Threaded` from the standard library. It was
originally written for [zio](https://lalinsky.github.io/zio/) though, and zio is still what we recommend
for production, especially if your handlers call other services over the network or you use WebSocket.

Dusty is written to run real services. It has been audited with
[HTTP Garden](https://github.com/narfindustries/http-garden) for parsing differences that could lead
to request smuggling, it has timeouts and connection limits on by default that work on every
`std.Io` implementation, and it's among the fastest servers on [HttpArena](https://http-arena.com/).

## Features

- Router with path parameters, wildcards, groups and per-group middleware
- HTTP/1.0 and HTTP/1.1, with chunked transfer encoding in both directions
- Transparent gzip/deflate decoding of request and response bodies
- Opt-in gzip compression of responses
- Server-Sent Events, and WebSocket on both the server and the client
- Static files with conditional and range requests, and assets embedded at build time
- HTTP and HTTPS client with connection pooling, and Unix socket support
- TLS on both sides, including client certificates, through [tls.zig](https://github.com/ianic/tls.zig)

## Quick Example

A server with two routes:

```zig
--8<-- "examples/hello_world.zig"
```

See [Getting Started](getting-started.md) for how to set up a project and run it, and
[Making Requests](client/requests.md) for the client.

## License

Dusty is licensed under the [MIT license](https://github.com/lalinsky/dusty/blob/main/LICENSE).
