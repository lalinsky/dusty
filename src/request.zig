const std = @import("std");

const http = @import("http.zig");
const RequestParser = @import("parser.zig").RequestParser;
const ServerConfig = @import("config.zig").ServerConfig;

pub const Request = struct {
    method: http.Method = undefined,
    url: []const u8 = "",
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: http.Headers = .{},
    content_type: ?http.ContentType = null,
    params: std.StringHashMapUnmanaged([]const u8) = .{},
    query: std.StringHashMapUnmanaged([]const u8) = .{},

    arena: std.mem.Allocator,

    // Body reading support
    parser: *RequestParser,
    conn: *std.Io.Reader,
    body_reader_buffer: [1024]u8 = undefined,
    config: ServerConfig.Request = .{},
    _body: ?[]const u8 = null,
    _body_read: bool = false,
    _fd: std.StringHashMapUnmanaged([]const u8) = .{},
    _fd_read: bool = false,

    pub fn reset(self: *Request) void {
        const arena = self.arena;
        const parser = self.parser;
        const conn = self.conn;
        const cfg = self.config;
        self.* = .{
            .arena = arena,
            .parser = parser,
            .conn = conn,
            .config = cfg,
        };
    }

    pub fn reader(self: *Request) BodyReader {
        // If body has already been read, return a reader for the cached body
        if (self._body_read) {
            const cached_body = self._body orelse &.{};
            return .{
                .req = self,
                .interface = std.Io.Reader.fixed(cached_body),
            };
        }

        // Otherwise return the streaming body reader
        return .{
            .req = self,
            .interface = .{
                .vtable = &.{
                    .stream = BodyReader.stream,
                },
                .buffer = &self.body_reader_buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// Read the entire body into memory. Result is cached for subsequent calls.
    pub fn body(self: *Request) !?[]const u8 {
        if (self._body_read) {
            return self._body;
        }

        var r = self.reader();
        const result = r.interface.allocRemaining(self.arena, .limited(self.config.max_body_size)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooBig,
            else => return err,
        };

        self._body_read = true;
        if (result.len == 0) {
            self._body = null;
            return null;
        }
        self._body = result;
        return result;
    }

    /// Parse body as JSON into type T
    pub fn json(self: *Request, comptime T: type) !?T {
        const b = try self.body() orelse return null;
        return try std.json.parseFromSliceLeaky(T, self.arena, b, .{});
    }

    /// Parse body as a generic JSON value
    pub fn jsonValue(self: *Request) !?std.json.Value {
        const b = try self.body() orelse return null;
        return try std.json.parseFromSliceLeaky(std.json.Value, self.arena, b, .{});
    }

    /// Parse body as a JSON object
    pub fn jsonObject(self: *Request) !?std.json.ObjectMap {
        const value = try self.jsonValue() orelse return null;
        switch (value) {
            .object => |o| return o,
            else => return null,
        }
    }

    /// Parse the body as a form (application/x-www-form-urlencoded)
    pub fn formData(self: *Request) !*std.StringHashMapUnmanaged([]const u8) {
        if (self._fd_read) {
            return &self._fd;
        }

        if (self.content_type == null or self.content_type != .form) {
            return error.NotForm;
        }

        const buffer = try self.body() orelse {
            self._fd_read = true;

            return &self._fd;
        };

        var entry_iterator = std.mem.splitScalar(u8, buffer, '&');

        while (entry_iterator.next()) |entry| {
            if (std.mem.indexOfScalar(u8, entry, '=')) |separator| {
                const key = try Request.urlUnescape(self.arena, entry[0..separator]);
                const value = try Request.urlUnescape(self.arena, entry[separator + 1 ..]);

                try self._fd.put(self.arena, key, value);
            } else {
                try self._fd.put(self.arena, try Request.urlUnescape(self.arena, entry), "");
            }
        }

        self._fd_read = true;

        return &self._fd;
    }

    /// Unescape a URL-encoded string
    /// Converts %XX hex sequences to bytes and + to space
    pub fn urlUnescape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var has_plus = false;
        var unescaped_len = input.len;

        var in_i: usize = 0;
        while (in_i < input.len) {
            const b = input[in_i];
            if (b == '%') {
                if (in_i + 2 >= input.len or !std.ascii.isHex(input[in_i + 1]) or !std.ascii.isHex(input[in_i + 2])) {
                    return error.InvalidEscapeSequence;
                }
                in_i += 3;
                unescaped_len -= 2;
            } else if (b == '+') {
                has_plus = true;
                in_i += 1;
            } else {
                in_i += 1;
            }
        }

        // no encoding, and no plus. nothing to unescape
        if (unescaped_len == input.len and !has_plus) {
            return input;
        }

        const out = try allocator.alloc(u8, unescaped_len);

        in_i = 0;
        for (0..unescaped_len) |i| {
            const b = input[in_i];
            if (b == '%') {
                out[i] = decodeHex(input[in_i + 1]) << 4 | decodeHex(input[in_i + 2]);
                in_i += 3;
            } else if (b == '+') {
                out[i] = ' ';
                in_i += 1;
            } else {
                out[i] = b;
                in_i += 1;
            }
        }

        return out;
    }

    fn decodeHex(c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'A'...'F' => c - 'A' + 10,
            'a'...'f' => c - 'a' + 10,
            else => 0,
        };
    }
};

pub const BodyReader = struct {
    req: *Request,
    interface: std.Io.Reader,

    fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));

        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;

        const conn = self.req.conn;
        const parser = self.req.parser;

        // Check if body is already complete
        if (parser.isBodyComplete()) {
            return error.EndOfStream;
        }

        // Setup destination for onBody callback (resets body_dest_pos to 0)
        parser.prepareBodyRead(dest);

        // Loop until we have body bytes, body is complete, or error occurs
        // This handles cases where parser consumes framing data (chunk headers)
        // but doesn't produce body bytes yet - we must not return 0 mid-body
        while (true) {
            // If we have body bytes, return them
            if (parser.state.body_dest_pos > 0) {
                w.advance(parser.state.body_dest_pos);
                return parser.state.body_dest_pos;
            }

            // Check if body is complete
            if (parser.isBodyComplete()) {
                return error.EndOfStream;
            }

            // Ensure connection buffer has data
            if (conn.bufferedLen() == 0) {
                conn.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        // Connection closed - call finish() to complete the message
                        parser.finish() catch {
                            // finish() failed - message was not complete
                            return error.ReadFailed;
                        };

                        // Check if body is now complete after finish()
                        if (parser.isBodyComplete()) {
                            return error.EndOfStream;
                        }

                        // Message not complete despite EOF
                        return error.ReadFailed;
                    },
                    else => return error.ReadFailed,
                };
            }

            // Get buffered data
            const buffered = conn.buffered();
            if (buffered.len == 0) {
                // Shouldn't happen after successful fillMore
                return error.EndOfStream;
            }

            // Limit feed size to available dest space to avoid consuming more than we can store
            const available = dest.len - parser.state.body_dest_pos;
            const to_feed = @min(buffered.len, available);

            // Feed data to parser (may consume framing data without producing body bytes)
            if (parser.feed(buffered[0..to_feed])) {
                // Not paused - consumed all bytes
                conn.toss(to_feed);
            } else |err| {
                switch (err) {
                    // Paused means onMessageComplete was called
                    error.Paused => {
                        const consumed = parser.getConsumedBytes(buffered.ptr);
                        conn.toss(consumed);
                    },
                    else => return error.ReadFailed,
                }
            }

            // Continue loop to check if we got body bytes now
        }
    }
};

/// Parse HTTP headers from a reader and prepare for body reading.
/// Returns error.EndOfStream if connection closed cleanly with no data.
/// Returns error.IncompleteRequest if connection closed mid-request.
pub fn parseHeaders(reader: *std.Io.Reader, parser: *RequestParser) !void {
    var parsed_len: usize = 0;
    while (!parser.state.headers_complete) {
        const buffered = reader.buffered();
        const unparsed = buffered[parsed_len..];
        if (unparsed.len > 0) {
            parser.feed(unparsed) catch |err| switch (err) {
                error.Paused => {
                    const consumed = parser.getConsumedBytes(unparsed.ptr);
                    parsed_len += consumed;
                    continue;
                },
                else => return err,
            };
            parsed_len += unparsed.len;
            continue;
        }
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                if (parsed_len == 0) return error.EndOfStream;
                return error.IncompleteRequest;
            },
            else => return err,
        };
    }
    reader.toss(parsed_len);
    parser.resumeParsing();

    // Feed empty buffer to advance state machine for bodyless requests
    parser.feed(&.{}) catch |err| switch (err) {
        error.Paused => {},
        else => return err,
    };
}

test "Request.body: basic POST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    var reader = std.Io.Reader.fixed(raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .conn = &reader,
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "Request.body: large body over 128 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body_content = "A" ** 256;
    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 256\r\n\r\n" ++ body_content;
    var reader = std.Io.Reader.fixed(raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .conn = &reader,
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqual(256, body.?.len);
    try std.testing.expectEqualStrings(body_content, body.?);
}

test "Request.formData: basic key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 15\r\n\r\nfoo=123&bar=abc";
    var reader = std.Io.Reader.fixed(raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .conn = &reader,
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.formData();
    try std.testing.expectEqualStrings("123", form_data.get("foo").?);
    try std.testing.expectEqualStrings("abc", form_data.get("bar").?);
}

test "Request.formData: URL-encoded key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 17\r\n\r\nfoo+bar=123%21abc";
    var reader = std.Io.Reader.fixed(raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .conn = &reader,
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.formData();
    try std.testing.expectEqualStrings("123!abc", form_data.get("foo bar").?);
}

test "Request.formData: entry with no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nfoo";
    var reader = std.Io.Reader.fixed(raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .conn = &reader,
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.formData();
    try std.testing.expectEqualStrings("", form_data.get("foo").?);
}
