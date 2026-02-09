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

    const body_reader = response.reader();
    var write_buf: [8192]u8 = undefined;
    var out = zio.stdout().writer(&write_buf);
    const total_bytes = try body_reader.streamRemaining(&out.interface);
    try out.interface.flush();
    std.debug.print("Total bytes: {d}\n", .{total_bytes});
}
