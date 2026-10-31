const std = @import("std");
const http = @import("dusty");

// --8<-- [start:download]
fn download(client: *http.Client, io: std.Io, url: []const u8, path: []const u8) !void {
    var response = try client.fetch(url, .{ .stream = true });
    defer response.deinit();

    if (response.status() != .ok) return error.UnexpectedStatus;

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var file_buf: [8192]u8 = undefined;
    var out = file.writer(io, &file_buf);

    var body = try response.reader(&.{});
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err.?,
        error.WriteFailed => return out.err.?,
    };
    try out.interface.flush();
}
// --8<-- [end:download]

// --8<-- [start:lines]
fn printLines(client: *http.Client, url: []const u8) !void {
    var response = try client.fetch(url, .{ .stream = true });
    defer response.deinit();

    var buf: [4096]u8 = undefined;
    var body = try response.reader(&buf);

    while (body.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return body.err.?,
        error.StreamTooLong => return err,
    }) |line| {
        std.debug.print("line: {s}\n", .{line});
    }
}
// --8<-- [end:lines]

pub fn main(init: std.process.Init) !void {
    var client = http.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    try download(&client, init.io, "https://ziglang.org/", "ziglang.html");
    try printLines(&client, "https://httpbin.org/stream/3");
}
