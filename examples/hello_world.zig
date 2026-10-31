const std = @import("std");
const http = @import("dusty");

fn hello(req: *http.Request, res: *http.Response) !void {
    const name = req.params.get("name") orelse "world";
    try res.print(.text, "Hello, {s}!\n", .{name});
}

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    server.router.get("/", hello);
    server.router.get("/hello/:name", hello);

    try server.run();
}
