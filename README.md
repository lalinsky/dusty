Dusty is a simple HTTP server built on top of [zio](https://github.com/lalinsky/zio) (coroutine/async engine) and [llhttp](https://github.com/nodejs/llhttp) (HTTP parser from NodeJS).
The API is very much inspired by Karl Seguin's [http.zig](https://github.com/karlseguin/http.zig), which is a great project and
I would be happy using that, if I didn't need to run multiple network services inside the same application. 

This project is in very early stages, don't use it unless you want to experiment or perhaps even contribute.

## Features
- Asynchronous I/O for multiple concurrent connections on a single CPU thread
- Requests handled in lightweight coroutines
- Router with support for parameters and wildcards
- Supports HTTP/1.0 and HTTP/1.1
- Supports chunked transfer encoding in both request/response bodies
- Server-Sent Events (SSE) for streaming responses
- WebSocket support (RFC 6455)
- Request/keepalive timeouts via coroutine auto-cancellation

## Example

```zig
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const AppContext = struct {
    rt: *zio.Runtime,
};

fn handleUser(ctx: *AppContext, req: *http.Request, res: *http.Response) !void {
    ctx.rt.sleep(100); // simulate some work
    const user_id = req.params.get("id") orelse "guest";
    try res.json(.{ .id = user_id, .name = "John Doe" }, .{});
}

// ...

fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime) !void {
    var ctx: AppContext = .{ .rt = rt };

    var server = http.Server(AppContext).init(allocator, .{}, &ctx);
    defer server.deinit();

    server.router.get("/user/:id", handleUser);
    server.router.get("/file/*path", handleFile);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);
    try server.listen(rt, addr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    try rt.runUntilComplete(runServer, .{ allocator, rt }, .{});
}
```
