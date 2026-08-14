const std = @import("std");
const http = @import("http.zig");
const Request = @import("request.zig").Request;
pub const WebSocket = @import("websocket.zig").WebSocket;
pub const CookieOpts = @import("cookie.zig").CookieOpts;
const serializeCookie = @import("cookie.zig").serializeCookie;
const Connection = @import("server.zig").Connection;

var no_buf: [0]u8 = .{};

pub const EventWriter = struct {
    conn: *std.Io.Writer,
    line_in_progress: bool,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *EventWriter = @fieldParentPtr("interface", w);
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |segment| {
            try writeLines(self, segment);
            total += segment.len;
        }
        if (splat > 0) {
            try writeLines(self, data[data.len - 1]);
            total += data[data.len - 1].len;
        }
        return w.consume(total);
    }

    fn writeLines(self: *EventWriter, bytes: []const u8) !void {
        var rest = bytes;
        while (std.mem.findScalar(u8, rest, '\n')) |idx| {
            if (!self.line_in_progress) try self.conn.writeAll("data: ");
            const line_end = if (idx > 0 and rest[idx - 1] == '\r') idx - 1 else idx;
            try self.conn.writeAll(rest[0..line_end]);
            try self.conn.writeAll("\n");
            self.line_in_progress = false;
            rest = rest[idx + 1 ..];
        }
        if (rest.len > 0) {
            if (!self.line_in_progress) {
                try self.conn.writeAll("data: ");
                self.line_in_progress = true;
            }
            try self.conn.writeAll(rest);
        }
    }

    pub fn end(self: *EventWriter) !void {
        try self.interface.flush();
        if (self.line_in_progress) try self.conn.writeAll("\n");
        try self.conn.writeAll("\n");
        try self.conn.flush();
    }
};

pub const EventStream = struct {
    conn: *std.Io.Writer,

    pub const Options = struct {
        event: ?[]const u8 = null,
        id: ?[]const u8 = null,
        retry: ?u32 = null,
    };

    pub fn startSend(self: EventStream, opts: Options) !EventWriter {
        if (opts.event) |e| if (std.mem.indexOfAny(u8, e, "\r\n") != null) return error.InvalidEventField;
        if (opts.id) |id| if (std.mem.indexOfAny(u8, id, "\r\n") != null) return error.InvalidEventField;

        if (opts.event) |e| try self.conn.print("event: {s}\n", .{e});
        if (opts.id) |id| try self.conn.print("id: {s}\n", .{id});
        if (opts.retry) |r| try self.conn.print("retry: {d}\n", .{r});

        return .{
            .conn = self.conn,
            .line_in_progress = false,
            .interface = .{
                .buffer = &no_buf,
                .vtable = &.{ .drain = &EventWriter.drain },
            },
        };
    }

    pub fn send(self: EventStream, data: []const u8, opts: Options) !void {
        if (opts.event) |e| if (std.mem.indexOfAny(u8, e, "\r\n") != null) return error.InvalidEventField;
        if (opts.id) |id| if (std.mem.indexOfAny(u8, id, "\r\n") != null) return error.InvalidEventField;

        if (opts.event) |e| try self.conn.print("event: {s}\n", .{e});
        if (opts.id) |id| try self.conn.print("id: {s}\n", .{id});
        if (opts.retry) |r| try self.conn.print("retry: {d}\n", .{r});
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const stripped = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
            try self.conn.print("data: {s}\n", .{stripped});
        }
        try self.conn.writeAll("\n");
        try self.conn.flush();
    }
};

/// Writes a response body, picking the framing from how much gets written.
///
/// Nothing is sent while the body still fits in the caller's buffer, so
/// `end` can send it with an exact `Content-Length`. The first drain --
/// the buffer overflowing, or the handler calling `flush` to start
/// streaming -- commits to chunked transfer encoding, because from then on
/// the length is not known in advance.
///
/// The buffer only has to outlive the handler if `end` is not called, and
/// `end` must be called, so a stack buffer is fine.
pub const BodyWriter = struct {
    res: *Response,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed` that the
    /// `std.Io.Writer` interface has to return. Recorded when a write
    /// fails, so a handler that catches one can find out what happened
    /// instead of being told only that it did.
    err: ?Error = null,

    /// Everything `writeHeader` can fail with, plus the real transport
    /// errors hiding behind `WriteFailed`.
    pub const Error = Connection.WriteError || HeaderError;

    const HeaderError = @typeInfo(@typeInfo(@TypeOf(Response.writeHeader)).@"fn".return_type.?).error_union.error_set;

    fn init(res: *Response, buf: []u8) BodyWriter {
        return .{
            .res = res,
            .interface = .{
                .buffer = buf,
                .vtable = &.{ .drain = BodyWriter.drain },
            },
        };
    }

    /// Runs `result`, recording what actually went wrong. The interface
    /// still reports the generic `WriteFailed`, as its contract requires;
    /// `err` is where the answer lives.
    fn record(self: *BodyWriter, result: HeaderError!void) std.Io.Writer.Error!void {
        result catch |e| {
            self.err = if (e == error.WriteFailed)
                self.res.conn.getWriteError() orelse e
            else
                e;
            return error.WriteFailed;
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BodyWriter = @alignCast(@fieldParentPtr("interface", w));
        const res = self.res;

        // Getting here at all means the body outgrew the buffer, or the
        // handler asked to start streaming. Either way the length can no
        // longer be stated up front.
        if (!res.chunked) {
            res.chunked = true;
            try self.record(res.writeHeader());
        }

        const pending = w.buffered();
        const total = pending.len + std.Io.Writer.countSplat(data, splat);
        // A zero length chunk is the terminator, so an empty flush has to
        // send nothing at all rather than ending the body early.
        if (total == 0) return 0;

        try self.record(self.writeChunk(pending, data, splat, total));
        return w.consume(total);
    }

    fn writeChunk(
        self: *BodyWriter,
        pending: []const u8,
        data: []const []const u8,
        splat: usize,
        total: usize,
    ) std.Io.Writer.Error!void {
        // 16 hex digits covers any usize, plus the CRLF.
        var size_buf: [18]u8 = undefined;
        const size = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{total}) catch unreachable;

        const out = self.res.conn.writer;
        try out.writeAll(size);
        try out.writeAll(pending);
        for (data[0 .. data.len - 1]) |bytes| try out.writeAll(bytes);
        const pattern = data[data.len - 1];
        for (0..splat) |_| try out.writeAll(pattern);
        try out.writeAll("\r\n");
        try out.flush();
    }

    /// Finishes the body. Must be called before the handler returns: until
    /// it does, a buffered body has not been sent and a chunked one has no
    /// terminator.
    pub fn end(self: *BodyWriter) !void {
        const res = self.res;
        std.debug.assert(res.body_writer_open);
        res.body_writer_open = false;

        if (res.chunked) {
            try self.record(self.interface.flush());
            try self.record(res.conn.writer.writeAll("0\r\n\r\n"));
        } else {
            // Never drained, so the whole body is still in the buffer and
            // its length is known.
            const body = self.interface.buffered();
            res.body = body;
            defer res.body = "";
            try self.record(res.writeHeader());
            try self.record(res.conn.writer.writeAll(body));
        }
        try self.record(res.conn.writer.flush());
        res.written = true;
    }
};

pub const Response = struct {
    status: http.Status = .ok,
    body: []const u8 = "",
    headers: http.Headers = .{},
    content_type: ?http.ContentType = null,
    arena: std.mem.Allocator,
    buffer: std.Io.Writer.Allocating,
    conn: *Connection,
    written: bool = false,
    headers_written: bool = false,
    keepalive: bool = true,
    chunked: bool = false,
    streaming: bool = false,
    /// A `BodyWriter` was handed out and has not been ended yet.
    body_writer_open: bool = false,

    pub fn init(arena: std.mem.Allocator, conn: *Connection, max_headers: usize) !Response {
        return .{
            .arena = arena,
            .buffer = .init(arena),
            .conn = conn,
            .headers = try http.Headers.init(arena, max_headers),
        };
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        try http.validateHeaderName(name);
        try http.validateHeaderValue(value);
        try self.headers.put(name, value);
    }

    /// A writer for the response body. `buf` holds the body until it
    /// overflows or is flushed; see `BodyWriter`. Call `end` on the result
    /// before returning from the handler.
    pub fn writer(self: *Response, buf: []u8) BodyWriter {
        std.debug.assert(!self.body_writer_open); // one body writer per response
        std.debug.assert(!self.headers_written); // body cannot start after the headers
        std.debug.assert(self.body.len == 0 and self.buffer.writer.end == 0); // body already set
        self.body_writer_open = true;
        return .init(self, buf);
    }

    pub fn clearWriter(self: *Response) void {
        _ = self.buffer.writer.consumeAll();
    }

    pub fn json(self: *Response, value: anytype, options: std.json.Stringify.Options) !void {
        const json_formatter = std.json.fmt(value, options);
        try json_formatter.format(&self.buffer.writer);
        try self.header("Content-Type", "application/json; charset=UTF-8");
    }

    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, opts: CookieOpts) !void {
        const serialized = try serializeCookie(self.arena, name, value, opts);
        try http.validateHeaderValue(serialized);
        try self.headers.add("Set-Cookie", serialized);
    }

    pub fn startEventStream(self: *Response) !EventStream {
        try self.header("Content-Type", "text/event-stream");
        try self.header("Cache-Control", "no-cache");
        self.keepalive = false;
        self.streaming = true;
        try self.writeHeader();
        try self.conn.writer.flush();
        return .{ .conn = self.conn.writer };
    }

    /// Upgrade HTTP connection to WebSocket.
    /// Returns null if request is not a valid WebSocket upgrade request.
    pub fn upgradeWebSocket(self: *Response, req: *Request) !?WebSocket {
        // Validate upgrade headers
        const upgrade = req.headers.get("Upgrade") orelse return null;
        if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return null;

        const connection = req.headers.get("Connection") orelse return null;
        if (std.ascii.indexOfIgnoreCase(connection, "upgrade") == null) return null;

        const version = req.headers.get("Sec-WebSocket-Version") orelse return null;
        if (!std.mem.eql(u8, version, "13")) return null;

        const key = req.headers.get("Sec-WebSocket-Key") orelse return null;

        // Compute accept key
        var accept_key: [28]u8 = undefined;
        WebSocket.computeAcceptKey(key, &accept_key);

        // Send 101 Switching Protocols response
        self.status = .switching_protocols;
        try self.header("Upgrade", "websocket");
        try self.header("Connection", "Upgrade");
        try self.header("Sec-WebSocket-Accept", &accept_key);
        self.streaming = true;
        try self.writeHeader();
        try self.conn.writer.flush();

        var seed: u64 = undefined;
        req.io.random(std.mem.asBytes(&seed));
        return WebSocket.init(req.io, self.conn.writer, req.conn, self.arena, seed);
    }

    pub fn writeHeader(self: *Response) !void {
        if (self.headers_written) {
            return;
        }
        self.headers_written = true;

        // Write status line
        try self.conn.writer.print("HTTP/1.1 {d} {f}\r\n", .{ @intFromEnum(self.status), self.status });

        // Set the Content-Type header
        if (self.content_type) |content_type| {
            try self.header("Content-Type", content_type.toContentType());
        }

        // Write headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            try self.conn.writer.print("{s}: {s}\r\n", .{ entry.key, entry.value });
        }

        // Write Connection header based on keepalive
        if (!self.keepalive) {
            try self.conn.writer.writeAll("Connection: close\r\n");
        }

        // Write Transfer-Encoding or Content-Length
        if (self.chunked) {
            try self.conn.writer.writeAll("Transfer-Encoding: chunked\r\n");
        } else if (!self.streaming) {
            // Write Content-Length if not manually set (skip for streaming responses like SSE)
            const has_content_length = self.headers.get("Content-Length") != null;
            if (!has_content_length) {
                const buffer_end = self.buffer.writer.end;
                const body_len = if (buffer_end > 0) buffer_end else self.body.len;
                try self.conn.writer.print("Content-Length: {d}\r\n", .{body_len});
            }
        }

        // End of headers (applies to both chunked and non-chunked)
        try self.conn.writer.writeAll("\r\n");

        // Don't flush here - let the caller flush after writing (the first part of) the body
    }

    pub fn write(self: *Response) !void {
        if (self.written) {
            return;
        }
        // The body writer's buffer belongs to the handler and is gone by
        // now, so there is nothing left that could finish the response.
        std.debug.assert(!self.body_writer_open); // handler returned without calling end()
        self.written = true;

        if (self.chunked) {
            // For chunked responses, headers are already written by chunk()
            // We just need to write the final zero-length chunk terminator
            try self.conn.writer.writeAll("0\r\n\r\n");
            try self.conn.writer.flush();
            return;
        }

        // Write headers if not already written
        try self.writeHeader();

        // Write body (either from buffer or body field)
        const buffered = self.buffer.writer.buffered();
        const body = if (buffered.len > 0) buffered else self.body;
        try self.conn.writer.writeAll(body);

        try self.conn.writer.flush();
    }
};

test "BodyWriter: a body that fits is sent with a Content-Length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = response.writer(&body_buf);
    try body.interface.writeAll("Hello, ");
    try body.interface.writeAll("World!");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 13\r\n" ++
            "\r\n" ++
            "Hello, World!",
        conn_writer.buffered(),
    );
    try std.testing.expect(!response.chunked);
}
test "BodyWriter: overflowing the buffer switches to chunked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    // Too small for the body, so the first write has to drain.
    var body_buf: [8]u8 = undefined;
    var body = response.writer(&body_buf);
    try body.interface.print("Hello, {s}! You are {d}.", .{ "Alice", 30 });
    try body.end();

    const written = conn_writer.buffered();
    try std.testing.expect(response.chunked);
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "0\r\n\r\n"));
}
test "BodyWriter: flush starts streaming before the buffer is full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = response.writer(&body_buf);
    try body.interface.writeAll("first");
    // Plenty of room left, but the handler wants it on the wire now.
    try body.interface.flush();
    try std.testing.expect(response.chunked);

    try body.interface.writeAll("second");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nfirst\r\n" ++
            "6\r\nsecond\r\n" ++
            "0\r\n\r\n",
        conn_writer.buffered(),
    );
}
test "Response: body used when buffer is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
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

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.body = "Hello World";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello World") != null);
}

test "BodyWriter: writes between flushes are framed as one chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = response.writer(&body_buf);
    try body.interface.writeAll("aaa");
    try body.interface.writeAll("bbb");
    try body.interface.print("{d}", .{42});
    try body.interface.flush();
    try body.end();

    // One chunk for all three writes, not three.
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "8\r\naaabbb42\r\n" ++
            "0\r\n\r\n",
        conn_writer.buffered(),
    );
}
test "Response: write() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
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

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
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

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
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

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
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

test "BodyWriter: an empty flush does not terminate the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = response.writer(&body_buf);
    try body.interface.writeAll("first");
    try body.interface.flush();
    // Nothing buffered: a zero length chunk here would end the body early.
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nfirst\r\n" ++
            "6\r\nsecond\r\n" ++
            "0\r\n\r\n",
        conn_writer.buffered(),
    );
}
test "Response: keepalive defaults to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
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

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.keepalive = false;
    response.body = "test";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") != null);
}

test "BodyWriter: headers set before the body are sent with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.status = .created;
    try response.header("X-Custom", "value");

    var body_buf: [8]u8 = undefined;
    var body = response.writer(&body_buf);
    try body.interface.writeAll("Data that does not fit");
    try body.end();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 201 CREATED\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: value") != null);
}
test "Response: chunked flag defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    const response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectEqual(false, response.chunked);
}

test "BodyWriter: records the real error behind error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Too small to hold the headers, so the first drain fails.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response.init(arena.allocator(), &connection, 32);
    var body_buf: [2]u8 = undefined;
    var body = response.writer(&body_buf);

    // The interface reports the generic error, as it must.
    try std.testing.expectError(error.WriteFailed, body.interface.writeAll("too long for the buffer"));
    // The answer is on the writer.
    try std.testing.expectEqual(error.ConnectionResetByPeer, body.err.?);
}
test "BodyWriter: falls back to WriteFailed when nothing was recorded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    var body_buf: [2]u8 = undefined;
    var body = response.writer(&body_buf);

    try std.testing.expectError(error.WriteFailed, body.interface.writeAll("too long for the buffer"));
    try std.testing.expectEqual(error.WriteFailed, body.err.?);
}
test "Response: json() with simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.json(.{ .name = "Alice", .age = 30 }, .{});

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", buffered);

    // Check that Content-Type was set
    const content_type = response.headers.get("Content-Type");
    try std.testing.expect(content_type != null);
    try std.testing.expectEqualStrings("application/json; charset=UTF-8", content_type.?);
}

test "Response: json() writes complete response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    response.status = .created;
    try response.json(.{ .id = 123, .message = "Created" }, .{});
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 201") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type: application/json; charset=UTF-8") != null);
    // Check the actual JSON content length: {"id":123,"message":"Created"}
    const expected_json = "{\"id\":123,\"message\":\"Created\"}";
    try std.testing.expect(std.mem.indexOf(u8, written, expected_json) != null);

    // Build expected content-length string
    var cl_buf: [32]u8 = undefined;
    const cl_str = try std.fmt.bufPrint(&cl_buf, "Content-Length: {d}", .{expected_json.len});
    try std.testing.expect(std.mem.indexOf(u8, written, cl_str) != null);
}

test "Response: json() with array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    try response.json(items, .{});

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("[1,2,3,4,5]", buffered);
}

test "Response: json() with nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.json(.{
        .user = .{
            .name = "Bob",
            .id = 42,
        },
        .active = true,
    }, .{});

    const buffered = response.buffer.writer.buffered();
    try std.testing.expectEqualStrings("{\"user\":{\"name\":\"Bob\",\"id\":42},\"active\":true}", buffered);
}

test "EventStream: send with data only" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try stream.send("hello world", .{});

    const written = conn_writer.buffered();
    try std.testing.expectEqualStrings("data: hello world\n\n", written);
}

test "EventStream: send with event name" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try stream.send("payload", .{ .event = "update" });

    const written = conn_writer.buffered();
    try std.testing.expectEqualStrings("event: update\ndata: payload\n\n", written);
}

test "EventStream: send with all options" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try stream.send("payload", .{ .event = "update", .id = "42", .retry = 5000 });

    const written = conn_writer.buffered();
    try std.testing.expectEqualStrings("event: update\nid: 42\nretry: 5000\ndata: payload\n\n", written);
}

test "EventStream: multiple sends" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try stream.send("first", .{});
    try stream.send("second", .{ .event = "msg" });

    const written = conn_writer.buffered();
    try std.testing.expectEqualStrings("data: first\n\nevent: msg\ndata: second\n\n", written);
}

test "Response: startEventStream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    const stream = try response.startEventStream();

    try stream.send("connected", .{});

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type: text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Cache-Control: no-cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "data: connected\n\n") != null);
    try std.testing.expectEqual(false, response.keepalive);
}

test "Response: setCookie basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.setCookie("session", "abc123", .{});
    response.body = "OK";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Set-Cookie: session=abc123\r\n") != null);
}

test "Response: setCookie with options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try response.setCookie("auth", "token123", .{
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = .strict,
    });
    response.body = "OK";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Set-Cookie: auth=token123; Path=/; HttpOnly; Secure; SameSite=Strict\r\n") != null);
}

test "Response: header() rejects CRLF in value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderValue, response.header("Location", "/ok\r\nX-Evil: 1"));
    try std.testing.expectError(error.InvalidHeaderValue, response.header("X-Foo", "bar\nbaz"));
    try std.testing.expectError(error.InvalidHeaderValue, response.header("X-Foo", "bar\x00baz"));
}

test "Response: header() rejects invalid name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderName, response.header("", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X-Bad\r\n", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X: Bad", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X Bad", "value"));
}

test "Response: setCookie rejects CRLF via header()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response.init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderValue, response.setCookie("session", "abc\r\nSet-Cookie: evil=1", .{}));
}

test "EventStream: rejects newline in event and id fields" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try std.testing.expectError(error.InvalidEventField, stream.send("ok", .{ .event = "bad\nevent" }));
    try std.testing.expectError(error.InvalidEventField, stream.send("ok", .{ .id = "bad\rid" }));
}

test "EventStream: multi-line data splits into multiple data lines" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try stream.send("line1\nline2", .{});

    const written = conn_writer.buffered();
    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", written);
}

test "EventStream: CRLF line endings stripped in data" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    try stream.send("line1\r\nline2", .{});

    const written = conn_writer.buffered();
    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", written);
}

test "EventWriter: basic write" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{});
    try ew.interface.writeAll("hello");
    try ew.end();

    try std.testing.expectEqualStrings("data: hello\n\n", conn_writer.buffered());
}

test "EventWriter: multi-line" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{});
    try ew.interface.writeAll("line1\nline2");
    try ew.end();

    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", conn_writer.buffered());
}

test "EventWriter: print" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{});
    try ew.interface.print("count: {d}", .{42});
    try ew.end();

    try std.testing.expectEqualStrings("data: count: 42\n\n", conn_writer.buffered());
}

test "EventWriter: with options" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{ .event = "update", .id = "42" });
    try ew.interface.writeAll("payload");
    try ew.end();

    try std.testing.expectEqualStrings("event: update\nid: 42\ndata: payload\n\n", conn_writer.buffered());
}

test "EventWriter: multiple writes merged into one event" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{});
    try ew.interface.writeAll("foo");
    try ew.interface.writeAll("bar");
    try ew.end();

    try std.testing.expectEqualStrings("data: foobar\n\n", conn_writer.buffered());
}

test "EventWriter: writeByte" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{});
    try ew.interface.writeByte('A');
    try ew.interface.writeByte('B');
    try ew.interface.writeByte('C');
    try ew.end();

    try std.testing.expectEqualStrings("data: ABC\n\n", conn_writer.buffered());
}

test "EventWriter: splatBytesAll" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    const stream = EventStream{ .conn = &conn_writer };
    var ew = try stream.startSend(.{});
    try ew.interface.splatBytesAll("ab", 3);
    try ew.end();

    try std.testing.expectEqualStrings("data: ababab\n\n", conn_writer.buffered());
}
