Dusty is a HTTP client/server library built on top of [zio](https://github.com/lalinsky/zio) (coroutine/async engine) and [llhttp](https://github.com/nodejs/llhttp) (HTTP parser from NodeJS).
The server API is inspired by Karl Seguin's [http.zig](https://github.com/karlseguin/http.zig), and tries to be as compatible as possible. By using a coroutine scheduler under the hood, it's very easy to efficiently wait for a HTTP client request in a HTTP server handler, or perhaps have a long-runing WebSocket session and don't worry about state management between callbacks.

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

## Server Example

```zig
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

fn handleUser(req: *http.Request, res: *http.Response) !void {
    const user_id = req.params.get("id") orelse "guest";
    try res.json(.{ .id = user_id, .name = "John Doe" }, .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var server = http.Server(void).init(allocator, .{}, {});
    defer server.deinit();

    server.router.get("/user/:id", handleUser);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);
    try server.listen(addr);
}
```

## Client Example

```zig
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var client = http.Client.init(allocator, .{});
    defer client.deinit();

    var response = try client.fetch("http://httpbin.org/get", .{});
    defer response.deinit();

    std.debug.print("Status: {t}\n", .{response.status()});

    if (try response.body()) |body| {
        std.debug.print("Body: {s}\n", .{body});
    }
}
```
