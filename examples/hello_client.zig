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
