Dusty is a HTTP client/server library built on top of Zig's standard library I/O interface (`std.Io`) and [llhttp](https://github.com/nodejs/llhttp) (HTTP parser from NodeJS).

The library was originally written for [zio](https://github.com/lalinsky/zio), and later ported to `std.Io`. It's still recommended to use it with zio's
implementation of the `std.Io` interface, especially if you need to communicate with other services over the network in your HTTP request handlers,
or if you are using WebSocket. However, it's usable with any implementation, like `std.Io.Threaded`, or even the simulated implementation from [Marionette](https://github.com/sb2bg/marionette).

The server API is inspired by Karl Seguin's [http.zig](https://github.com/karlseguin/http.zig), and tries to be as compatible as possible.

## Features
- Router with support for parameters and wildcards
- Supports HTTP/1.0 and HTTP/1.1
- Supports chunked transfer encoding in both request/response bodies
- Server-Sent Events (SSE) for streaming responses
- WebSocket support (RFC 6455)
- HTTP/HTTPS client with connection pooling
- Unix domain socket support for client connections
- Optional TLS support in both client and server, including mTLS for authentication (via [tls.zig](https://github.com/ianic/tls.zig))

## Installation

```sh
zig fetch --save "git+https://github.com/lalinsky/dusty"
```

Then in your `build.zig`, add the module as a dependency:

```zig
const dusty = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dusty", dusty.module("dusty"));
```

## Usage

### Server Example

```zig
const std = @import("std");
const http = @import("dusty");

fn handleUser(req: *http.Request, res: *http.Response) !void {
    const user_id = req.params.get("id") orelse "guest";
    try req.io.sleep(.fromMilliseconds(10), .real);
    try res.json(.{ .id = user_id, .name = "John Doe" }, .{});
}

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{}, {});
    defer server.deinit();

    server.router.get("/user/:id", handleUser);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };
    try server.listen(addr);
}
```

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

The server side is symmetric — `client_auth` makes it ask connecting clients for a certificate:

```zig
var server = http.Server(void).init(gpa, io, .{
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
}, {});
```

### Unix Socket Client Example

For communicating with services like Docker Engine:

```zig
var response = try client.fetch("http://localhost/v1.41/info", .{
    .unix_socket_path = "/var/run/docker.sock",
});
defer response.deinit();
```

## Selecting the I/O Backend

The examples above use `init.io`, the threaded I/O implementation from the stdlib. This is suitable for development or small servers.

For production use, it's recommended to use [zio](https://github.com/lalinsky/zio), which provides a coroutine-based async I/O runtime.
This allows you to serve many more requests using just a few OS threads. This is especially important if you need to wait on other
network services inside your request handlers. In the future, you can also use `std.Io.Evented`, but that implementation is not finished yet,
it's missing any networking functionality, so use zio for now.

Add it as a dependency:

```sh
zig fetch --save "git+https://github.com/lalinsky/zio#v0.10.0"
```

In `build.zig`, add the zio module:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zio", zio.module("zio"));
```

Then initialize zio's runtime and pass it to dusty:

```zig
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    var server = http.Server(void).init(init.gpa, rt.io(), .{}, {});
    defer server.deinit();

    // ... continue as before ...
}
```
