const std = @import("std");
const dusty = @import("../root.zig");
const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

/// Serves `dir` at `prefix`, sends `request` on one connection and returns
/// everything the server sent back before closing it.
fn exchange(dir: std.Io.Dir, prefix: []const u8, opts: dusty.StaticOptions, request: []const u8, out: []u8) ![]const u8 {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.static(prefix, dir, opts);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.ready.wait(io);
    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var sink: std.Io.Writer = .fixed(out);
    _ = reader.interface.streamRemaining(&sink) catch {};
    return sink.buffered();
}

fn testDir() !std.testing.TmpDir {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "style.css", .data = "body { color: red }" });
    try tmp.dir.createDir(io, "docs", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/index.html", .data = "<h1>docs</h1>" });
    return tmp;
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

test "static: serves a file with its type and length" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const got = try exchange(tmp.dir, "/assets", .{}, "GET /assets/style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("text/css; charset=UTF-8", header(got, "Content-Type").?);
    try std.testing.expectEqualStrings("19", header(got, "Content-Length").?);
    try std.testing.expect(header(got, "ETag") != null);
    try std.testing.expectEqualStrings("body { color: red }", body(got));
}

test "static: HEAD reports the length and sends no body" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const got = try exchange(tmp.dir, "/assets", .{}, "HEAD /assets/style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("19", header(got, "Content-Length").?);
    try std.testing.expectEqualStrings("", body(got));
}

test "static: a matching If-None-Match is a 304" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const first = try exchange(tmp.dir, "/", .{}, "GET /style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    var etag_buf: [64]u8 = undefined;
    const etag = etag_buf[0..header(first, "ETag").?.len];
    @memcpy(etag, header(first, "ETag").?);

    var request_buf: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, "GET /style.css HTTP/1.1\r\nHost: x\r\nIf-None-Match: W/{s}\r\nConnection: close\r\n\r\n", .{etag});
    const got = try exchange(tmp.dir, "/", .{}, request, &out);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 304"));
    try std.testing.expectEqualStrings(etag, header(got, "ETag").?);
    try std.testing.expectEqualStrings("", body(got));
}

test "static: a directory redirects to its slash, then serves its index" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const redirect = try exchange(tmp.dir, "/", .{}, "GET /docs?x=1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, redirect, "HTTP/1.1 301"));
    try std.testing.expectEqualStrings("/docs/?x=1", header(redirect, "Location").?);

    // Not `//docs/`, which a browser would take for a host.
    const doubled = try exchange(tmp.dir, "/", .{}, "GET //docs HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expectEqualStrings("/docs/", header(doubled, "Location").?);

    const index = try exchange(tmp.dir, "/", .{}, "GET /docs/ HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, index, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("text/html; charset=UTF-8", header(index, "Content-Type").?);
    try std.testing.expectEqualStrings("<h1>docs</h1>", body(index));
}

test "static: missing files and escapes from the directory are 404s" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    for ([_][]const u8{
        "GET /assets/nope.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        "GET /assets/../style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        "GET /assets/%2e%2e/style.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        "GET /assets/docs/..%2f..%2fstyle.css HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        "GET /assets/style.css/ HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    }) |request| {
        const got = try exchange(tmp.dir, "/assets", .{}, request, &out);
        try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 404"));
    }
}

/// A GET of `/style.css` with `headers` added, on its own connection.
fn getStyle(dir: std.Io.Dir, headers: []const u8, out: []u8) ![]const u8 {
    var request_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, "GET /style.css HTTP/1.1\r\nHost: x\r\n{s}Connection: close\r\n\r\n", .{headers});
    return exchange(dir, "/", .{}, request, out);
}

test "static: a range is a 206 with that part of the file" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const got = try getStyle(tmp.dir, "Range: bytes=5-9\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 206"));
    try std.testing.expectEqualStrings("bytes 5-9/19", header(got, "Content-Range").?);
    try std.testing.expectEqualStrings("5", header(got, "Content-Length").?);
    try std.testing.expectEqualStrings("{ col", body(got));

    const suffix = try getStyle(tmp.dir, "Range: bytes=-3\r\n", &out);
    try std.testing.expectEqualStrings("bytes 16-18/19", header(suffix, "Content-Range").?);
    try std.testing.expectEqualStrings("d }", body(suffix));
}

test "static: a range past the end is a 416" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const got = try getStyle(tmp.dir, "Range: bytes=19-\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 416"));
    try std.testing.expectEqualStrings("bytes */19", header(got, "Content-Range").?);
    try std.testing.expectEqualStrings("", body(got));
}

test "static: Last-Modified drives If-Modified-Since, If-Unmodified-Since and If-Range" {
    var tmp = try testDir();
    defer tmp.cleanup();

    var out: [4096]u8 = undefined;
    const first = try getStyle(tmp.dir, "", &out);
    try std.testing.expectEqualStrings("bytes", header(first, "Accept-Ranges").?);
    var date_buf: [64]u8 = undefined;
    const last_modified = date_buf[0..header(first, "Last-Modified").?.len];
    @memcpy(last_modified, header(first, "Last-Modified").?);

    var headers_buf: [256]u8 = undefined;

    const not_modified = try getStyle(tmp.dir, try std.fmt.bufPrint(&headers_buf, "If-Modified-Since: {s}\r\n", .{last_modified}), &out);
    try std.testing.expect(std.mem.startsWith(u8, not_modified, "HTTP/1.1 304"));

    const modified = try getStyle(tmp.dir, "If-Modified-Since: Thu, 01 Jan 1970 00:00:00 GMT\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, modified, "HTTP/1.1 200"));

    const failed = try getStyle(tmp.dir, "If-Unmodified-Since: Thu, 01 Jan 1970 00:00:00 GMT\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, failed, "HTTP/1.1 412"));
    try std.testing.expectEqualStrings("", body(failed));

    const ranged = try getStyle(tmp.dir, try std.fmt.bufPrint(&headers_buf, "Range: bytes=0-3\r\nIf-Range: {s}\r\n", .{last_modified}), &out);
    try std.testing.expect(std.mem.startsWith(u8, ranged, "HTTP/1.1 206"));

    // A validator that no longer matches gets the whole file.
    const stale = try getStyle(tmp.dir, "Range: bytes=0-3\r\nIf-Range: \"stale\"\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, stale, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("body { color: red }", body(stale));
}

test "static: a precompressed copy is served to a client that accepts it" {
    const io = std.testing.io;
    var tmp = try testDir();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "style.css.gz", .data = "gzipped" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/index.html.br", .data = "brotli" });
    const opts: dusty.StaticOptions = .{ .precompressed = &.{ .br, .gzip } };

    var out: [4096]u8 = undefined;
    const gzipped = try exchange(tmp.dir, "/", opts, "GET /style.css HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br, gzip\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, gzipped, "HTTP/1.1 200"));
    try std.testing.expectEqualStrings("gzip", header(gzipped, "Content-Encoding").?);
    try std.testing.expectEqualStrings("text/css; charset=UTF-8", header(gzipped, "Content-Type").?);
    try std.testing.expectEqualStrings("Accept-Encoding", header(gzipped, "Vary").?);
    try std.testing.expect(std.mem.endsWith(u8, header(gzipped, "ETag").?, "-gzip\""));
    try std.testing.expectEqualStrings("gzipped", body(gzipped));

    const plain = try exchange(tmp.dir, "/", opts, "GET /style.css HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expectEqual(null, header(plain, "Content-Encoding"));
    try std.testing.expectEqualStrings("Accept-Encoding", header(plain, "Vary").?);
    try std.testing.expectEqualStrings("body { color: red }", body(plain));

    const index = try exchange(tmp.dir, "/", opts, "GET /docs/ HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, br\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expectEqualStrings("br", header(index, "Content-Encoding").?);
    try std.testing.expectEqualStrings("text/html; charset=UTF-8", header(index, "Content-Type").?);
    try std.testing.expectEqualStrings("brotli", body(index));
}

test "static: something other than a regular file is a 404" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = try testDir();
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "/dev/null", "null", .{});

    var out: [4096]u8 = undefined;
    const got = try exchange(tmp.dir, "/", .{}, "GET /null HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 404"));
}
