Dusty is a HTTP client/server library built on top of Zig's standard library async I/O (`std.Io`) and [llhttp](https://github.com/nodejs/llhttp) (HTTP parser from NodeJS).
The server API is inspired by Karl Seguin's [http.zig](https://github.com/karlseguin/http.zig), and tries to be as compatible as possible. By using coroutines under the hood, it's very easy to efficiently wait for a HTTP client request in a HTTP server handler, or perhaps have a long-running WebSocket session and not worry about state management between callbacks.

## Features
- Asynchronous I/O for multiple concurrent connections on a single CPU thread
- Requests handled in lightweight coroutines
- Router with support for parameters and wildcards
- Supports HTTP/1.0 and HTTP/1.1
- Supports chunked transfer encoding in both request/response bodies
- Server-Sent Events (SSE) for streaming responses
- WebSocket support (RFC 6455)
- Request/keepalive timeouts via coroutine auto-cancellation
- HTTP/HTTPS client with connection pooling
- Unix domain socket support for client connections

## Installation

```sh
zig fetch --save "git+https://github.com/lalinsky/dusty#v0.2.0"
```

Then in your `build.zig`, add the module as a dependency:

```zig
const dusty = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dusty", dusty.module("dusty"));
```

## Server Example

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

## Client Example

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

### Unix Socket Example

For communicating with services like Docker Engine:

```zig
var response = try client.fetch("http://localhost/v1.41/info", .{
    .unix_socket_path = "/var/run/docker.sock",
});
defer response.deinit();
```

## Selecting the I/O Backend

The examples above use `init.io`, the threaded I/O provided by `std.process.Init`. This is suitable for small servers and scripts without long-running tasks.

For production use, it's recommended to use [zio](https://github.com/lalinsky/zio), which provides a high-performance coroutine-based async runtime. Add it as a dependency:

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

    // ... router setup ...

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };
    try server.listen(addr);
}
```
