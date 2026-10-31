const std = @import("std");
const http = @import("dusty");

fn index(res: *http.Response) !void {
    try res.print(.text, "Hello, world!\n", .{});
}

fn hello(name: http.Param("name", []const u8), res: *http.Response) !void {
    try res.print(.text, "Hello, {s}!\n", .{name.value});
}

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    server.router.get("/", index);
    server.router.get("/hello/:name", hello);

    try server.run();
}
