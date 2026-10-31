# Dusty

Dusty is an HTTP client and server library for Zig. It's built on the standard library's
[`std.Io`](https://ziglang.org/documentation/0.16.0/std/#std.Io) interface, and parses HTTP with
[llhttp](https://github.com/nodejs/llhttp), the parser from Node.js.

It runs on any `std.Io` implementation that supports networking, including `std.Io.Threaded` from
the standard library. It was originally written for [zio](https://lalinsky.github.io/zio/) though,
and zio is still what we recommend for production, especially if your handlers call other services
over the network or you use WebSocket.

A lot of work has gone into making Dusty both reliable and fast. Timeouts and connection limits are
on by default, and they work on every `std.Io` implementation. The HTTP parsing has been checked
with [HTTP Garden](https://github.com/narfindustries/http-garden) for differences that could lead to
request smuggling. And on [HttpArena](https://http-arena.com/), it's among the fastest servers.

## Features

- Router with path parameters, wildcards, groups and per-group middleware
- HTTP/1.0 and HTTP/1.1, with chunked transfer encoding in both directions
- Transparent gzip/deflate decoding of request and response bodies
- Opt-in gzip compression of responses
- Server-Sent Events, and WebSocket on both the server and the client
- Static files with conditional and range requests, and assets embedded at build time
- HTTP and HTTPS client with connection pooling, and Unix socket support
- TLS on both sides, including client certificates, through [tls.zig](https://github.com/lalinsky/tls.zig)

## Quick Example

A server with two routes:

```zig
--8<-- "examples/hello_world.zig"
```

And a client that calls it:

```zig
--8<-- "examples/hello_client.zig"
```

See [Getting Started](getting-started.md) for how to set up a project and run the server, and
[Making Requests](client/requests.md) for more about the client.

## Zig Versions

Dusty works with Zig 0.16 and 0.17. Both are tested on Linux, macOS and Windows.

## Examples

The code in these docs comes from the programs in the
[examples](https://github.com/lalinsky/dusty/tree/main/examples) directory.
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo) is a complete app, with
templates, a PostgreSQL database and live updates over Server-Sent Events.

## License

Dusty is licensed under the [MIT license](https://github.com/lalinsky/dusty/blob/main/LICENSE).
