Dusty is a simple HTTP server built on top of [zio](https://github.com/lalinsky/zio) and [llhttp](https://github.com/nodejs/llhttp).
The API is very much inspired by Karl Seguin's [http.zig](https://github.com/karlseguin/http.zig), which is a great project and
I would be happy using that, if I didn't need to run multiple network services inside the same application. 

This is project is in very early stages, don't use it unless you want to experiment or perhaps even contribute.

## Features
- Asynchronous I/O for multiple concurrent connections on a single CPU thread
- Requests handled in lightweight coroutines
- Router with support for parameters and wildcards
- Supports HTTP/1.0 and HTTP/1.1
- Supports chunked transfer encoding in both request/response bodies

## Example

```zig
const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const AppContext = struct {};

fn handleIndex(ctx: *AppContext, req: *const http.Request, res: *http.Response) !void {
    _ = ctx;
    _ = req;
    res.body = "Hello World!\n";
}

// ...

fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime) !void {
    var ctx: AppContext = .{};

    var server = http.Server(AppContext).init(allocator, &ctx);
    defer server.deinit();

    server.router.get("/", handleIndex);
    server.router.get("/file/:id", handleFile);
    server.router.post("/download/*path", handleDownload);

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
