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

    var response = try client.fetch(rt, "http://httpbin.org/get", .{});
    defer response.deinit();

    std.debug.print("Status: {t}\n", .{response.status()});

    std.debug.print("Headers:\n", .{});
    var it = response.headers().iterator();
    while (it.next()) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    if (try response.body()) |body| {
        std.debug.print("Body: {s}\n", .{body});
    }
}
