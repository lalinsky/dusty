const std = @import("std");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("Usage: {s} <url>\n", .{args[0]});
        std.debug.print("Example: {s} https://httpbin.org/get\n", .{args[0]});
        std.process.exit(1);
    }

    const url = args[1];

    var client = http.Client.init(allocator, io, .{});
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
    var out = std.Io.File.stdout().writer(io, &write_buf);
    const total_bytes = try body_reader.streamRemaining(&out.interface);
    try out.interface.flush();
    std.debug.print("Total bytes: {d}\n", .{total_bytes});
}
