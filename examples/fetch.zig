const std = @import("std");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    var client = http.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    var response = try client.fetch("https://ziglang.org/", .{});
    defer response.deinit();

    const body = try response.body() orelse "";
    std.debug.print("{d} {s}, {d} bytes\n", .{ @intFromEnum(response.status()), @tagName(response.status()), body.len });
}
