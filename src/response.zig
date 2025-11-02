const std = @import("std");
const http = @import("http.zig");

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: http.Headers = .{},
    arena: std.mem.Allocator,
    buffer: std.Io.Writer.Allocating,
    conn: *std.Io.Writer,
    written: bool = false,
    headers_written: bool = false,
    keepalive: bool = true,

    pub fn init(arena: std.mem.Allocator, conn: *std.Io.Writer) Response {
        return .{
            .arena = arena,
            .buffer = .init(arena),
            .conn = conn,
        };
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.put(self.arena, name, value);
    }

    pub fn writer(self: *Response) *std.Io.Writer {
        return &self.buffer.writer;
    }

    pub fn clearWriter(self: *Response) void {
        _ = self.buffer.writer.consumeAll();
    }

    pub fn writeHeader(self: *Response) !void {
        if (self.headers_written) {
            return;
        }
        self.headers_written = true;

        // Write status line
        try self.conn.print("HTTP/1.1 {d} {f}\r\n", .{ @intFromEnum(self.status), self.status });

        // Write headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            try self.conn.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Write Connection header based on keepalive
        if (!self.keepalive) {
            try self.conn.writeAll("Connection: close\r\n");
        }

        // Write Content-Length if not manually set
        const has_content_length = self.headers.get("Content-Length") != null;
        if (!has_content_length) {
            const buffer_end = self.buffer.writer.end;
            const body_len = if (buffer_end > 0) buffer_end else self.body.len;
            try self.conn.print("Content-Length: {d}\r\n", .{body_len});
        }

        // End of headers
        try self.conn.writeAll("\r\n");
        try self.conn.flush();
    }

    pub fn write(self: *Response) !void {
        if (self.written) {
            return;
        }
        self.written = true;

        // Write headers if not already written
        try self.writeHeader();

        // Write body (either from buffer or body field)
        const buffered = self.buffer.writer.buffered();
        const body = if (buffered.len > 0) buffered else self.body;
        try self.conn.writeAll(body);

        try self.conn.flush();
    }
};

test "Response: basic writer usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    const w = response.writer();

    try w.writeAll("Hello, ");
    try w.writeAll("World!");

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("Hello, World!", buffered);
}

test "Response: writer with formatted output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    const w = response.writer();

    try w.print("Hello, {s}! You are {d} years old.", .{ "Alice", 30 });

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("Hello, Alice! You are 30 years old.", buffered);
}

test "Response: buffer takes precedence over body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.body = "body content";

    const w = response.writer();
    try w.writeAll("writer content");

    // Buffer should have content
    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("writer content", buffered);
    try std.testing.expect(buffered.len > 0);

    // Body is still there but shouldn't be used
    try std.testing.expectEqualStrings("body content", response.body);
}

test "Response: body used when buffer is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.body = "body content";

    // Don't write to buffer
    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("", buffered);
    try std.testing.expect(buffered.len == 0);

    // Body should be used
    try std.testing.expectEqualStrings("body content", response.body);
}

test "Response: write() with body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.body = "Hello World";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello World") != null);
}

test "Response: write() with writer buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    const w = response.writer();
    try w.print("Count: {d}", .{42});

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Count: 42") != null);
}

test "Response: write() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.body = "First";

    try response.write();
    const first_len = conn_writer.end;

    // Try writing again with different body
    response.body = "Second";
    try response.write();

    // Should still be the same length (no second write)
    try std.testing.expectEqual(first_len, conn_writer.end);
}

test "Response: writeHeader() basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.status = .created;
    try response.header("X-Custom", "value");
    response.body = "Hello";

    try response.writeHeader();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 201") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: value") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    // Body should not be written yet
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello") == null);
}

test "Response: writeHeader() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.body = "Test";

    try response.writeHeader();
    const first_len = conn_writer.end;

    // Try writing header again with different status
    response.status = .bad_request;
    try response.writeHeader();

    // Should still be the same length (no second write)
    try std.testing.expectEqual(first_len, conn_writer.end);
}

test "Response: write() after writeHeader() doesn't duplicate headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.body = "Body content";

    // Write headers first
    try response.writeHeader();
    const header_len = conn_writer.end;

    // Now write the full response (should only add body)
    try response.write();
    const full_len = conn_writer.end;

    // Check that body was added
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Body content") != null);

    // Length should have increased by body length only
    try std.testing.expect(full_len > header_len);
    try std.testing.expectEqual(header_len + "Body content".len, full_len);
}

test "Response: clearWriter()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    const w = response.writer();

    try w.writeAll("First content");
    try std.testing.expectEqualStrings("First content", response.buffer.writer.buffered());

    response.clearWriter();
    try std.testing.expectEqualStrings("", response.buffer.writer.buffered());

    try w.writeAll("Second content");
    try std.testing.expectEqualStrings("Second content", response.buffer.writer.buffered());
}

test "Response: keepalive defaults to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    try std.testing.expectEqual(true, response.keepalive);

    response.body = "test";
    try response.write();

    const written = conn_writer.buffered();
    // Should not have Connection: close header when keepalive is true
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") == null);
}

test "Response: Connection close header when keepalive is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var response = Response.init(arena.allocator(), &conn_writer);
    response.keepalive = false;
    response.body = "test";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") != null);
}
