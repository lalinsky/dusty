# Dusty - HTTP client/server library for Zig

[![CI](https://github.com/lalinsky/dusty/actions/workflows/test.yml/badge.svg)](https://github.com/lalinsky/dusty/actions/workflows/test.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.17.0-orange.svg)](https://ziglang.org/download/)
[![Documentation](https://img.shields.io/badge/docs-online-green.svg)](https://lalinsky.github.io/dusty/)
[![HTTP Arena H1](https://img.shields.io/endpoint?url=https://http-arena.com/badge/dusty/h1.json)](https://http-arena.com/#type=emerging,flagship&tuned=0)
[![HTTP Arena WebSocket](https://img.shields.io/endpoint?url=https://http-arena.com/badge/dusty/ws.json)](https://http-arena.com/#scope=ws&type=emerging,flagship&tuned=0)

Dusty is an HTTP client and server library for Zig. It's built on the standard library's
[`std.Io`](https://ziglang.org/documentation/0.16.0/std/#std.Io) interface, and parses HTTP with
[llhttp](https://github.com/nodejs/llhttp), the parser from Node.js.

It runs on any `std.Io` implementation that supports networking, including `std.Io.Threaded` from
the standard library, or even the simulated one from [Marionette](https://github.com/sb2bg/marionette).
It was originally written for [zio](https://github.com/lalinsky/zio) though, and zio is still what
we recommend for production, especially if your handlers call other services over the network or
you use WebSocket.

A lot of work has gone into making Dusty both reliable and fast. Timeouts and connection limits are
on by default, and they work on every `std.Io` implementation. The HTTP parsing has been checked
with [HTTP Garden](https://github.com/narfindustries/http-garden) for differences that could lead to
request smuggling. And on [HttpArena](https://http-arena.com/), it's among the fastest servers.

See the [documentation](https://lalinsky.github.io/dusty/) for the full guide.

## Features

- Router with path parameters, wildcards, groups and per-group middleware
- HTTP/1.0 and HTTP/1.1, with chunked transfer encoding in both directions
- Transparent gzip and deflate decoding of request and response bodies, and optional gzip compression of responses
- Server-Sent Events, and WebSocket on both the server and the client
- Static files with conditional and range requests, and assets embedded at build time
- HTTP and HTTPS client with connection pooling, and Unix socket support
- TLS on both sides, including client certificates, through [tls.zig](https://github.com/lalinsky/tls.zig)

## Installation

Requires Zig 0.16 or 0.17.

1) Add Dusty as a dependency in your `build.zig.zon`:

```sh
zig fetch --save "git+https://github.com/lalinsky/dusty"
```

2) In your `build.zig`, add the `dusty` module as a dependency to your program:

```zig
const dusty_dep = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("dusty", dusty_dep.module("dusty"));
```

See [Build Options](https://lalinsky.github.io/dusty/build-options/) for how to configure the package.

## Usage

A server with two routes:

```zig
const std = @import("std");
const http = @import("dusty");

const App = struct {
    greeting: []const u8,
};

fn index(app: *App, res: *http.Response) !void {
    try res.print(.text, "{s}, world!\n", .{app.greeting});
}

fn hello(app: *App, name: http.Param("name", []const u8), res: *http.Response) !void {
    try res.print(.text, "{s}, {s}!\n", .{ app.greeting, name.value });
}

pub fn main(init: std.process.Init) !void {
    var app: App = .{ .greeting = "Hello" };

    var server = http.Server(App).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, &app);
    defer server.deinit();

    server.router.get("/", index);
    server.router.get("/hello/:name", hello);

    try server.run();
}
```

And a client that calls it:

```zig
const std = @import("std");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    var client = http.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    var response = try client.fetch("http://127.0.0.1:8080/hello/zig", .{});
    defer response.deinit();

    const body = try response.body() orelse "";
    std.debug.print("{d}: {s}", .{ @intFromEnum(response.status()), body });
}
```

The documentation covers the rest:

- [Getting Started](https://lalinsky.github.io/dusty/getting-started/)
- Server: [routing](https://lalinsky.github.io/dusty/server/routing/),
  [handlers](https://lalinsky.github.io/dusty/server/handlers/),
  [middleware](https://lalinsky.github.io/dusty/server/middleware/),
  [templating](https://lalinsky.github.io/dusty/server/templating/),
  [static files](https://lalinsky.github.io/dusty/server/static-files/),
  [WebSocket](https://lalinsky.github.io/dusty/server/websocket/),
  [deployment on zio](https://lalinsky.github.io/dusty/server/deployment/)
- Client: [making requests](https://lalinsky.github.io/dusty/client/requests/),
  [streaming](https://lalinsky.github.io/dusty/client/streaming/),
  [WebSocket](https://lalinsky.github.io/dusty/client/websocket/)
- [API reference](https://lalinsky.github.io/dusty/apidocs/)

[examples/todo](examples/todo) is a complete app built with [zt](https://github.com/lalinsky/zt),
[pg.zig](https://github.com/lalinsky/pg.zig) and [htmx](https://htmx.org), with live updates
across browser tabs over Server-Sent Events.

## Recommended libraries

Databases:

- [pg.zig](https://github.com/lalinsky/pg.zig) - PostgreSQL client (fork that uses [tls.zig](https://github.com/ianic/tls.zig) instead of `OpenSSL` for `std.Io` compatibility)
- [mysql](https://github.com/speed2exe/myzql) - MySQL client
- [redis.zig](https://github.com/lalinsky/redis.zig) - Redis client
- [memcached.zig](https://github.com/lalinsky/memcached.zig) - Memcached client

Message brokers:

- [nats.zig](https://github.com/lalinsky/nats.zig) - NATS client library

Serialization:

- [msgpack.zig](https://github.com/lalinsky/msgpack.zig) - Fast MsgPack serialization library for static types
- [json.zig](https://github.com/lalinsky/json.zig) - Fast JSON serialization library for static types

Templating:

- [zt](https://github.com/lalinsky/zt) - Templating language inspired by Go Templ

Others:

- [xsync.zig](https://github.com/lalinsky/xsync.zig) - Synchronization primitives that work across multiple `std.Io` implementations

## Development

Format the code and run the tests:

```sh
./check.sh
```

Build the examples:

```sh
zig build examples
```

## License

This project is licensed under the [MIT license](LICENSE).
