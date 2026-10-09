const std = @import("std");
const dusty = @import("dusty");
const assets = @import("assets");

fn get(server: *dusty.Server(void), path: []const u8, headers: []const u8, out: []u8) ![]const u8 {
    const io = std.testing.io;
    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\n{s}Connection: close\r\n\r\n", .{ path, headers });
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var sink: std.Io.Writer = .fixed(out);
    _ = reader.interface.streamRemaining(&sink) catch {};
    return sink.buffered();
}

fn header(response: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn body(response: []const u8) []const u8 {
    const end = std.mem.find(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

test "assets: the bundle lists its files, without dotfiles or compressed copies" {
    try std.testing.expectEqual(2, assets.files.len);
    try std.testing.expectEqualStrings("app.css", assets.files[0].name);
    try std.testing.expectEqualStrings("gzipped", assets.files[0].gzip.?);
    try std.testing.expectEqualStrings("img/logo.svg", assets.files[1].name);

    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, "body { color: red }"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "/assets/app.css?v={x:0>8}", .{hash}), assets.url("app.css"));
}

test "assets: cached for good at the current version, revalidated at any other" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }},
    }, {});
    defer server.deinit();
    assets.register(&server.router);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.ready.wait(io);

    var out: [4096]u8 = undefined;
    const hashed = try get(&server, assets.url("img/logo.svg"), "", &out);
    try std.testing.expect(std.mem.startsWith(u8, hashed, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("image/svg+xml", header(hashed, "Content-Type").?);
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", header(hashed, "Cache-Control").?);
    try std.testing.expectEqualStrings("<svg/>", body(hashed));

    const stale = try get(&server, "/assets/img/logo.svg?v=0", "", &out);
    try std.testing.expect(std.mem.startsWith(u8, stale, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("no-cache", header(stale, "Cache-Control").?);
    try std.testing.expectEqualStrings("<svg/>", body(stale));

    const plain = try get(&server, "/assets/app.css", "Accept-Encoding: gzip\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, plain, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("no-cache", header(plain, "Cache-Control").?);
    try std.testing.expectEqualStrings("gzip", header(plain, "Content-Encoding").?);
    try std.testing.expectEqualStrings("gzipped", body(plain));

    const hidden = try get(&server, "/assets/.hidden", "", &out);
    try std.testing.expect(std.mem.startsWith(u8, hidden, "HTTP/1.1 404"));
}
