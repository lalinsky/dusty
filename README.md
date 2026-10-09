Dusty is a HTTP client/server library built on top of Zig's standard library I/O interface (`std.Io`) and [llhttp](https://github.com/nodejs/llhttp) (HTTP parser from NodeJS).

The library was originally written for [zio](https://github.com/lalinsky/zio), and later ported to `std.Io`. It's still recommended to use it with zio's
implementation of the `std.Io` interface, especially if you need to communicate with other services over the network in your HTTP request handlers,
or if you are using WebSocket. However, it's usable with any implementation, like `std.Io.Threaded`, or even the simulated implementation from [Marionette](https://github.com/sb2bg/marionette).

## Features
- Router with support for parameters and wildcards
- Supports HTTP/1.0 and HTTP/1.1
- Supports chunked transfer encoding in both request/response bodies
- Transparent gzip/deflate decoding of request and response bodies
- gzip compression of response bodies, opt-in per response with `res.compress = true`
- Server-Sent Events (SSE) for streaming responses
- Static file serving with conditional and range requests, and precompressed files
- WebSocket support (RFC 6455)
- HTTP/HTTPS client with connection pooling
- Unix domain socket support for client connections
- Optional TLS support in both client and server, including mTLS for authentication (via [tls.zig](https://github.com/ianic/tls.zig))

## Installation

Requires Zig 0.16 or 0.17.

```sh
zig fetch --save "git+https://github.com/lalinsky/dusty#v0.4.0"
```

Then in your `build.zig`, add the module as a dependency:

```zig
const dusty = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dusty", dusty.module("dusty"));
```

### Using a custom tls.zig

TLS is enabled with Dusty's pinned tls.zig dependency by default. To inject a
different compatible version without fetching or compiling the bundled one,
disable only the bundled provider and replace the `tls` import:

```zig
const dusty = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
    .use_tls = true,
    .use_bundled_tls = false,
});
const custom_tls = b.dependency("custom_tls", .{
    .target = target,
    .optimize = optimize,
});

const dusty_mod = dusty.module("dusty");
dusty_mod.addImport("tls", custom_tls.module("tls"));
exe.root_module.addImport("dusty", dusty_mod);
```

The application declares `custom_tls` in its own `build.zig.zon`, so it can
point to another commit, fork, or local path. Omitting the injected module is a
compile error. Use `.use_tls = false` instead when TLS should be compiled out.

## Usage

### Server Example

```zig
const std = @import("std");
const http = @import("dusty");

fn handleUser(req: *http.Request, res: *http.Response) !void {
    const user_id = req.params.get("id") orelse "guest";
    try req.io.sleep(.fromMilliseconds(10), .real);
    try res.print(.text, "Hello, user {s}!\n", .{user_id});
}

pub fn main(init: std.process.Init) !void {
    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{ .address = addr }},
    }, {});
    defer server.deinit();

    server.router.get("/user/:id", handleUser);

    try server.run();
}
```

`listeners` takes any number of listeners, each with its own TLS, so one server
can serve HTTPS on 443 and plain HTTP on 80 with the same router:

```zig
.listeners = &.{
    .{ .address = addr443, .tls = .{ .cert_path = "server.pem", .key_path = "server.key" } },
    .{ .address = addr80 },
},
```

When `listeners` is omitted or empty, the server listens on `127.0.0.1:8080`.

A handler can tell them apart through `req.listener` and `req.secure`, and
`server.addresses` has each listener's bound address once `server.ready` is set.

### Templating

Dusty has no templating system of its own. We recommend [zt](https://github.com/lalinsky/zt),
which compiles templates to Zig at build time. A template in `src/templates/pages.zt`:

```zig
pub templ UserPage(name: []const u8, admin: bool) {
    <html>
        <body>
            <h1>Hello, {name}</h1>
            if (admin) {
                <p>You are an admin.</p>
            }
        </body>
    </html>
}
```

`res.render` writes it into the response with the given content type:

```zig
const pages = @import("templates/pages.zig");

fn handleUser(req: *http.Request, res: *http.Response) !void {
    const name = req.params.get("name") orelse "guest";
    try res.render(.html, pages.UserPage, .{ name, false });
}
```

`res.render` also takes a plain function whose last parameter is the `*std.Io.Writer`.
For something small, `res.print(.html, "<p>Hello, {s}</p>", .{name})` formats the body directly.

[examples/todo](examples/todo) is a complete app built with zt, [pg.zig](https://github.com/lalinsky/pg.zig)
and [htmx](https://htmx.org), with live updates across browser tabs over Server-Sent Events.

### Serialization

`res.encode` writes a value with a serializer's write-to-writer function, telling its parameters
apart by type, so libraries plug in as they are. We recommend
[json.zig](https://github.com/lalinsky/json.zig) for JSON and
[msgpack.zig](https://github.com/lalinsky/msgpack.zig) for MessagePack, both specialized to your
types at compile time.

```zig
const json = @import("json");
const msgpack = @import("msgpack");

fn handleUser(req: *http.Request, res: *http.Response) !void {
    const input = try json.decodeFromSliceLeaky(UserInput, req.arena, try req.body() orelse "", .{});
    const user = try updateUser(input);
    try res.encode(.json, json.encode, user);
}

fn handleUserMsgpack(req: *http.Request, res: *http.Response) !void {
    const user = try loadUser(req.params.get("id").?);
    try res.encode(.msgpack, msgpack.encode, user);
}
```

Other serializers fit the same way, [serde.zig](https://github.com/OrlovEvgeny/serde.zig)'s `toWriter` for one. Unlike `std.json`, json.zig
leaves out optional fields that are null, unless the type says otherwise.

`res.json` and `req.json` are there for convenience. They use `std.json`, so they take any type,
`std.json.Value` included, but json.zig is considerably faster at both encoding and decoding.

### Static Files

`router.static` serves a directory under a prefix:

```zig
var public = try std.Io.Dir.cwd().openDir(io, "public", .{});
defer public.close(io);

server.router.static("/assets", public, .{
    // Serve style.css.br or style.css.gz in place of style.css when the client accepts them.
    .precompressed = &.{ .br, .gzip },
});
```

Responses carry `ETag` and `Last-Modified`, and the conditional and `Range` headers that use
them are honored. A directory serves its `index.html`; paths with `..` are 404s, and so are
dotfiles unless `.hide_dotfiles = false`. Symlinks are followed unless `.resolve_beneath = true`,
which depends on the platform.

`router.embedded` serves a single file compiled into the binary:

```zig
server.router.embedded("/assets/app.css", @embedFile("assets/app.css"), .{
    // Optional compressed copies, served to clients that accept them.
    .br = @embedFile("assets/app.css.br"),
});
```

The content type comes from the path's extension unless `.content_type` is set. The `ETag` is
a hash of the content, and there is no `Last-Modified`.

### Client Example

```zig
const std = @import("std");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    var client = http.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    var response = try client.fetch("http://httpbin.org/get", .{});
    defer response.deinit();

    std.debug.print("Status: {any}\n", .{response.status()});

    if (try response.body()) |body| {
        std.debug.print("Body: {s}\n", .{body});
    }
}
```

### HTTPS and Client Certificates

By default the client verifies servers against the system trust store. `ClientConfig.tls`
overrides that, and adds a client certificate for servers that require mutual TLS:

```zig
var client = http.Client.init(init.gpa, init.io, .{
    .tls = .{
        // .system (default), .{ .file = ... }, .{ .dir = ... }, or .none
        .ca = .{ .file = .{ .path = "ca.pem" } },
        // Presented when the server asks the client to authenticate itself.
        .client_certificate = .{ .cert_path = "client.pem", .key_path = "client.key" },
    },
});
```

The key must be an unencrypted PKCS#8 (`BEGIN PRIVATE KEY`) or SEC1 (`BEGIN EC PRIVATE KEY`) PEM file.

These settings apply to every connection a client makes; connections are pooled and reused
across requests, so they cannot be varied per request. Use a separate `Client` per identity.

The server side is symmetric. TLS is configured per listener, and `client_auth`
makes it ask connecting clients for a certificate:

```zig
.listeners = &.{.{
    .address = addr,
    .tls = .{
        .cert_path = "server.pem",
        .key_path = "server.key",
        .client_auth = .{
            .ca = .{ .file = .{ .path = "client-ca.pem" } },
            // .require (default) rejects a client that sends no certificate;
            // .request asks for one but accepts an empty reply.
            .mode = .require,
        },
    },
}},
```

### Unix Socket Client Example

For communicating with services like Docker Engine:

```zig
var response = try client.fetch("http://localhost/v1.41/info", .{
    .unix_socket_path = "/var/run/docker.sock",
});
defer response.deinit();
```

## Timeouts

Servers use finite timeouts by default so stalled or idle clients eventually
release their connection slots:

- `timeout.request` defaults to 30 seconds. It covers an entire request,
  including handler work and writing the response; a TLS handshake gets its own
  deadline of the same length.
- `timeout.keepalive` defaults to 60 seconds between requests on a persistent
  connection.
- `timeout.shutdown` defaults to 30 seconds for a graceful shutdown drain.

Set a configured timeout to `null` to disable it. A handler can also replace
its current request deadline with `Request.setTimeout`. It accepts
`std.Io.Timeout`, so the handler can use a relative duration, provide an exact
deadline, or disable the deadline with `.none`:

```zig
req.setTimeout(.{
    .duration = .{ .raw = .fromSeconds(60), .clock = .awake },
});
req.setTimeout(.{ .deadline = deadline });
req.setTimeout(.none);
```

Long-lived handlers can use this as an inactivity timeout by re-arming it
before each WebSocket message or event, without disabling the resilient server
default for ordinary requests.

The client bounds each request the same way. `ClientConfig.timeout` defaults
to 30 seconds and covers the whole of `fetch`: connecting, the TLS handshake,
sending the request, every redirect, and the response through the end of its
body, which `fetch` reads before returning. A request that runs past it fails
with `error.Timeout`. `FetchOptions.timeout` replaces the default for one
request:

```zig
var client = http.Client.init(gpa, io, .{ .timeout = .fromSeconds(5) });

// Inherits the five seconds.
var a = try client.fetch(url, .{});
// Its own limit, counted from this call.
var b = try client.fetch(url, .{
    .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
});
// An absolute deadline, such as one shared with other work.
var c = try client.fetch(url, .{ .timeout = .{ .deadline = deadline } });
// No limit at all.
var d = try client.fetch(url, .{ .timeout = .none });
```

A request with `.stream = true` leaves the body on the wire for the caller to
read through `ClientResponse.reader`. The deadline then covers `fetch` through
the end of the head, and the body reads are not bounded at all.

On zio, deadlines cancel the connection task directly, which needs a zio new
enough to have `AutoCancel.setClock`. Other I/O backends use a watchdog task;
with `std.Io.Threaded`, that means a second OS thread for each connection while
either request or keepalive timeouts are enabled, and on the client side a
second thread for each `fetch` while a timeout is set.

## Selecting the I/O Backend

The examples above use `init.io`, the threaded I/O implementation from the stdlib. This is suitable for development or small servers.

For production use, it's recommended to use [zio](https://github.com/lalinsky/zio), which provides a coroutine-based async I/O runtime.
This allows you to serve many more requests using just a few OS threads. This is especially important if you need to wait on other
network services inside your request handlers. In the future, you can also use `std.Io.Evented`, but that implementation is not finished yet,
it's missing any networking functionality, so use zio for now.

Add it as a dependency:

```sh
zig fetch --save "git+https://github.com/lalinsky/zio"
```

In `build.zig`, add the zio module:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zio", zio.module("zio"));
dusty.module("dusty").addImport("zio", zio.module("zio"));
```

Then initialize zio's runtime and pass it to dusty:

```zig
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .listeners = &.{.{ .address = addr }},
    }, {});
    defer server.deinit();

    // ... continue as before ...
}
```

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

- [zmpl](https://github.com/jetzig-framework/zmpl) - Templating language inspired by Go Templ
- [zt](https://github.com/lalinsky/zt) - Another templating language inspired by Go Templ

Others:

- [xsync.zig](https://github.com/lalinsky/xsync.zig) - Synchronization primitives that work across multiple `std.Io` implementations
