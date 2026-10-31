# Dusty

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

## Zig Versions

Dusty works with Zig 0.16 and 0.17. Both are tested on Linux, macOS and Windows.

## Build Options

TLS and gzip are compiled in by default. You can turn them off when you add the dependency in
`build.zig`:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .use_tls = false,
});
```

- `use_tls` builds in TLS through [tls.zig](https://github.com/ianic/tls.zig). Without it, HTTPS
  requests fail with `error.TlsNotConfigured`, and a server with a TLS listener fails to start.
- `use_zlib` builds in gzip and deflate through zlib. Without it, compressed bodies can't be decoded,
  and responses are sent uncompressed even when compression is turned on.

## Examples

The code in these docs comes from the programs in the
[examples](https://github.com/lalinsky/dusty/tree/main/examples) directory.
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo) is a complete app, with
templates, a PostgreSQL database and live updates over Server-Sent Events. It still needs Zig 0.16.

## License

Dusty is licensed under the [MIT license](https://github.com/lalinsky/dusty/blob/main/LICENSE).
