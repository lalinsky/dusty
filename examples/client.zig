const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <url>\n", .{args[0]});
        std.debug.print("Example: {s} https://httpbin.org/get\n", .{args[0]});
        std.process.exit(1);
    }

    const url = args[1];

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var client = http.Client.init(allocator, .{});
    defer client.deinit();

    var response = try client.fetch(url, .{});
    defer response.deinit();

    std.debug.print("Status: {any}\n", .{response.status()});

    std.debug.print("Headers:\n", .{});
    var it = response.headers().iterator();
    while (it.next()) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    std.debug.print("\n", .{});

    if (try response.body()) |body| {
        std.debug.print("{s}\n", .{body});
    }
}
