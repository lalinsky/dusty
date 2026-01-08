const std = @import("std");

const c = @cImport({
    @cInclude("llhttp.h");
});

const Method = @import("http.zig").Method;
const Status = @import("http.zig").Status;
const Headers = @import("http.zig").Headers;
const ContentType = @import("http.zig").ContentType;
const Request = @import("request.zig").Request;

pub const ParseError = error{
    InvalidMethod,
    InvalidUrl,
    InvalidHeaderToken,
    InvalidHeaderValue,
    InvalidVersion,
    InvalidStatus,
    InvalidChunkSize,
    UnexpectedContentLength,
    ClosedConnection,
    ParseFailed,
    Paused,
};

fn mapError(err: c.llhttp_errno_t) ParseError {
    return switch (err) {
        c.HPE_INVALID_METHOD => ParseError.InvalidMethod,
        c.HPE_INVALID_URL => ParseError.InvalidUrl,
        c.HPE_INVALID_HEADER_TOKEN => ParseError.InvalidHeaderToken,
        c.HPE_INVALID_VERSION => ParseError.InvalidVersion,
        c.HPE_INVALID_STATUS => ParseError.InvalidStatus,
        c.HPE_INVALID_CHUNK_SIZE => ParseError.InvalidChunkSize,
        c.HPE_UNEXPECTED_CONTENT_LENGTH => ParseError.UnexpectedContentLength,
        c.HPE_CLOSED_CONNECTION => ParseError.ClosedConnection,
        else => ParseError.ParseFailed,
    };
}

pub const RequestParser = struct {
    settings: c.llhttp_settings_t,
    parser: c.llhttp_t,
    request: *Request,
    state: State = .{},

    const State = struct {
        has_method: bool = false,
        has_version: bool = false,
        has_url: bool = false,

        // Temporary state for header parsing
        has_header_field: bool = false,
        header_field: []const u8 = "",
        header_value: []const u8 = "",

        headers_complete: bool = false,
        message_complete: bool = false,

        // Body reading state
        body_dest_buf: []u8 = &.{}, // Where onBody should copy to
        body_dest_pos: usize = 0, // How much onBody has written
    };

    pub fn init(self: *RequestParser, request: *Request) !void {
        self.* = .{
            .parser = undefined,
            .settings = undefined,
            .request = request,
        };

        self.settings = std.mem.zeroes(c.llhttp_settings_t);
        self.settings.on_method_complete = onMethod;
        self.settings.on_version_complete = onVersion;
        self.settings.on_url = onUrl;
        self.settings.on_url_complete = onUrlComplete;
        self.settings.on_header_field = onHeaderField;
        self.settings.on_header_field_complete = onHeaderFieldComplete;
        self.settings.on_header_value = onHeaderValue;
        self.settings.on_header_value_complete = onHeaderValueComplete;
        self.settings.on_headers_complete = onHeadersComplete;
        self.settings.on_body = onBody;
        self.settings.on_message_complete = onMessageComplete;

        c.llhttp_init(&self.parser, c.HTTP_REQUEST, &self.settings);
    }

    pub fn deinit(self: *RequestParser) void {
        _ = self;
    }

    pub fn reset(self: *RequestParser) void {
        self.state = .{};
        c.llhttp_reset(&self.parser);
    }

    pub fn feed(self: *RequestParser, data: []const u8) !void {
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);

        if (err == c.HPE_OK) {
            return;
        }

        if (err == c.HPE_PAUSED) {
            return error.Paused;
        }

        return mapError(err);
    }

    pub fn finish(self: *RequestParser) !void {
        const err = c.llhttp_finish(&self.parser);
        if (err != c.HPE_OK) {
            return mapError(err);
        }
    }

    pub fn shouldKeepAlive(self: *RequestParser) bool {
        return c.llhttp_should_keep_alive(&self.parser) != 0;
    }

    pub fn resumeParsing(self: *RequestParser) void {
        c.llhttp_resume(&self.parser);
    }

    pub fn prepareBodyRead(self: *RequestParser, dest: []u8) void {
        self.state.body_dest_buf = dest;
        self.state.body_dest_pos = 0;
    }

    pub fn getConsumedBytes(self: *RequestParser, buf_start: [*c]const u8) usize {
        const pos = c.llhttp_get_error_pos(&self.parser);
        return @intFromPtr(pos) - @intFromPtr(buf_start);
    }

    pub fn isBodyComplete(self: *RequestParser) bool {
        return self.state.message_complete;
    }

    pub fn messageNeedsEof(self: *RequestParser) bool {
        return c.llhttp_message_needs_eof(&self.parser) != 0;
    }

    fn appendSlice(target: *[]const u8, at: [*c]const u8, length: usize) void {
        if (target.len == 0) {
            target.* = at[0..length];
        } else {
            std.debug.assert(target.ptr + target.len == at);
            target.* = target.ptr[0 .. target.len + length];
        }
    }

    fn onMethod(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.has_method = true;
        self.request.method = @enumFromInt(c.llhttp_get_method(&self.parser));
        return 0;
    }

    fn onVersion(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.has_version = true;
        self.request.version_major = c.llhttp_get_http_major(&self.parser);
        self.request.version_minor = c.llhttp_get_http_minor(&self.parser);
        return 0;
    }

    // Callbacks - store slices directly without copying
    fn onUrl(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.request.url, at, length);
        return 0;
    }

    fn onUrlComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.has_url = true;
        return 0;
    }

    fn onHeaderField(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_field, at, length);
        return 0;
    }

    fn onHeaderFieldComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        std.debug.assert(self.state.header_field.len > 0);
        self.state.has_header_field = true;
        return 0;
    }

    fn onHeaderValue(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_value, at, length);
        return 0;
    }

    fn onHeaderValueComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);

        std.debug.assert(self.state.has_header_field);

        // Check header count limit
        if (self.request.headers.count() >= self.request.config.max_header_count) {
            return -1;
        }

        // Headers point directly into arena-allocated read buffer, no copy needed
        self.request.headers.put(self.request.arena, self.state.header_field, self.state.header_value) catch return -1;

        self.state.header_value = "";
        self.state.header_field = "";
        self.state.has_header_field = false;

        return 0;
    }

    fn onHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);

        if (self.request.headers.get("Content-Type")) |content_type| {
            self.request.content_type = ContentType.fromContentType(content_type);
        }

        self.state.headers_complete = true;
        return c.HPE_PAUSED; // Always pause so we can track consumed bytes
    }

    fn onBody(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);

        const available = self.state.body_dest_buf.len - self.state.body_dest_pos;
        const to_copy = @min(length, available);

        if (to_copy > 0) {
            @memcpy(self.state.body_dest_buf[self.state.body_dest_pos..][0..to_copy], at[0..to_copy]);
            self.state.body_dest_pos += to_copy;
        }

        return 0;
    }

    fn onMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.message_complete = true;
        // Pause so we can detect completion
        return c.HPE_PAUSED;
    }
};

/// Minimal struct for holding parsed HTTP response data.
/// Used by ResponseParser to store parsed fields.
pub const ParsedResponse = struct {
    status: Status = .ok,
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: Headers = .{},
    content_type: ?ContentType = null,
    arena: std.mem.Allocator,
};

/// HTTP response parser using llhttp.
/// Mirrors RequestParser but parses HTTP responses instead of requests.
pub const ResponseParser = struct {
    settings: c.llhttp_settings_t,
    parser: c.llhttp_t,
    response: *ParsedResponse,
    state: State = .{},

    const State = struct {
        has_status: bool = false,
        has_version: bool = false,

        // Temporary state for header parsing
        has_header_field: bool = false,
        header_field: []const u8 = "",
        header_value: []const u8 = "",

        headers_complete: bool = false,
        message_complete: bool = false,

        // Body reading state
        body_dest_buf: []u8 = &.{}, // Where onBody should copy to
        body_dest_pos: usize = 0, // How much onBody has written
    };

    pub fn init(self: *ResponseParser, response: *ParsedResponse) void {
        self.* = .{
            .parser = undefined,
            .settings = undefined,
            .response = response,
        };

        self.settings = std.mem.zeroes(c.llhttp_settings_t);
        self.settings.on_status_complete = onStatusComplete;
        self.settings.on_version_complete = onVersion;
        self.settings.on_header_field = onHeaderField;
        self.settings.on_header_field_complete = onHeaderFieldComplete;
        self.settings.on_header_value = onHeaderValue;
        self.settings.on_header_value_complete = onHeaderValueComplete;
        self.settings.on_headers_complete = onHeadersComplete;
        self.settings.on_body = onBody;
        self.settings.on_message_complete = onMessageComplete;

        c.llhttp_init(&self.parser, c.HTTP_RESPONSE, &self.settings);
    }

    pub fn deinit(self: *ResponseParser) void {
        _ = self;
    }

    pub fn reset(self: *ResponseParser) void {
        self.state = .{};
        c.llhttp_reset(&self.parser);
    }

    pub fn feed(self: *ResponseParser, data: []const u8) !void {
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);

        if (err == c.HPE_OK) {
            return;
        }

        if (err == c.HPE_PAUSED) {
            return error.Paused;
        }

        return mapError(err);
    }

    pub fn finish(self: *ResponseParser) !void {
        const err = c.llhttp_finish(&self.parser);
        if (err != c.HPE_OK) {
            return mapError(err);
        }
    }

    pub fn shouldKeepAlive(self: *ResponseParser) bool {
        return c.llhttp_should_keep_alive(&self.parser) != 0;
    }

    pub fn resumeParsing(self: *ResponseParser) void {
        c.llhttp_resume(&self.parser);
    }

    pub fn prepareBodyRead(self: *ResponseParser, dest: []u8) void {
        self.state.body_dest_buf = dest;
        self.state.body_dest_pos = 0;
    }

    pub fn getConsumedBytes(self: *ResponseParser, buf_start: [*c]const u8) usize {
        const pos = c.llhttp_get_error_pos(&self.parser);
        return @intFromPtr(pos) - @intFromPtr(buf_start);
    }

    pub fn isBodyComplete(self: *ResponseParser) bool {
        return self.state.message_complete;
    }

    pub fn messageNeedsEof(self: *ResponseParser) bool {
        return c.llhttp_message_needs_eof(&self.parser) != 0;
    }

    fn appendSlice(target: *[]const u8, at: [*c]const u8, length: usize) void {
        if (target.len == 0) {
            target.* = at[0..length];
        } else {
            std.debug.assert(target.ptr + target.len == at);
            target.* = target.ptr[0 .. target.len + length];
        }
    }

    fn onStatusComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        self.state.has_status = true;
        self.response.status = @enumFromInt(c.llhttp_get_status_code(&self.parser));
        return 0;
    }

    fn onVersion(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        self.state.has_version = true;
        self.response.version_major = c.llhttp_get_http_major(&self.parser);
        self.response.version_minor = c.llhttp_get_http_minor(&self.parser);
        return 0;
    }

    fn onHeaderField(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_field, at, length);
        return 0;
    }

    fn onHeaderFieldComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        std.debug.assert(self.state.header_field.len > 0);
        self.state.has_header_field = true;
        return 0;
    }

    fn onHeaderValue(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_value, at, length);
        return 0;
    }

    fn onHeaderValueComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);

        std.debug.assert(self.state.has_header_field);

        // Headers point directly into arena-allocated read buffer, no copy needed
        self.response.headers.put(self.response.arena, self.state.header_field, self.state.header_value) catch return -1;

        self.state.header_value = "";
        self.state.header_field = "";
        self.state.has_header_field = false;

        return 0;
    }

    fn onHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);

        if (self.response.headers.get("Content-Type")) |content_type| {
            self.response.content_type = ContentType.fromContentType(content_type);
        }

        self.state.headers_complete = true;
        return c.HPE_PAUSED; // Always pause so we can track consumed bytes
    }

    fn onBody(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);

        const available = self.state.body_dest_buf.len - self.state.body_dest_pos;
        const to_copy = @min(length, available);

        if (to_copy > 0) {
            @memcpy(self.state.body_dest_buf[self.state.body_dest_pos..][0..to_copy], at[0..to_copy]);
            self.state.body_dest_pos += to_copy;
        }

        return 0;
    }

    fn onMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        self.state.message_complete = true;
        // Pause so we can detect completion
        return c.HPE_PAUSED;
    }
};

/// Generic streaming body reader for HTTP messages.
/// Works with any parser type that has the standard body reading interface:
/// - `state.body_dest_pos: usize`
/// - `isBodyComplete() bool`
/// - `prepareBodyRead(dest: []u8) void`
/// - `feed(data: []const u8) !void`
/// - `finish() !void`
/// - `getConsumedBytes(ptr: [*c]const u8) usize`
pub fn BodyReader(comptime Parser: type) type {
    return struct {
        parser: *Parser,
        conn: *std.Io.Reader,
        interface: std.Io.Reader,

        const Self = @This();

        pub fn init(parser: *Parser, conn: *std.Io.Reader, buffer: []u8) Self {
            return .{
                .parser = parser,
                .conn = conn,
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));
            const parser = self.parser;
            const conn = self.conn;

            const dest = limit.slice(try w.writableSliceGreedy(1));
            if (dest.len == 0) return 0;

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
}

/// BodyReader specialized for HTTP requests.
pub const RequestBodyReader = BodyReader(RequestParser);

/// BodyReader specialized for HTTP responses.
pub const ResponseBodyReader = BodyReader(ResponseParser);

/// Parsed Keep-Alive header parameters.
pub const KeepAliveParams = struct {
    timeout: ?u32 = null, // seconds until idle connection closes
    max: ?u32 = null, // max requests on this connection
};

/// Parse Keep-Alive header value into structured parameters.
/// Format: "timeout=5, max=100" or "timeout=5" or "max=100"
pub fn parseKeepAliveHeader(value: []const u8) KeepAliveParams {
    var params: KeepAliveParams = .{};

    var it = std.mem.splitSequence(u8, value, ",");
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (std.mem.startsWith(u8, trimmed, "timeout=")) {
            params.timeout = std.fmt.parseInt(u32, trimmed["timeout=".len..], 10) catch null;
        } else if (std.mem.startsWith(u8, trimmed, "max=")) {
            params.max = std.fmt.parseInt(u32, trimmed["max=".len..], 10) catch null;
        }
    }

    return params;
}

test "parseKeepAliveHeader: both params" {
    const params = parseKeepAliveHeader("timeout=5, max=100");
    try std.testing.expectEqual(5, params.timeout);
    try std.testing.expectEqual(100, params.max);
}

test "parseKeepAliveHeader: timeout only" {
    const params = parseKeepAliveHeader("timeout=30");
    try std.testing.expectEqual(30, params.timeout);
    try std.testing.expectEqual(null, params.max);
}

test "parseKeepAliveHeader: max only" {
    const params = parseKeepAliveHeader("max=10");
    try std.testing.expectEqual(null, params.timeout);
    try std.testing.expectEqual(10, params.max);
}

test "parseKeepAliveHeader: whitespace tolerance" {
    const params = parseKeepAliveHeader("timeout=5 , max=100");
    try std.testing.expectEqual(5, params.timeout);
    try std.testing.expectEqual(100, params.max);
}

test "parseKeepAliveHeader: invalid values ignored" {
    const params = parseKeepAliveHeader("timeout=abc, max=100");
    try std.testing.expectEqual(null, params.timeout);
    try std.testing.expectEqual(100, params.max);
}

test "parseKeepAliveHeader: empty string" {
    const params = parseKeepAliveHeader("");
    try std.testing.expectEqual(null, params.timeout);
    try std.testing.expectEqual(null, params.max);
}

test "RequestParser: basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req: Request = .{
        .arena = arena.allocator(),
        .parser = undefined,
        .conn = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();

    const request = "GET /example HTTP/1.1\r\nHost: example.com\r\n\r\n";

    // We will feed it the requst 1 byte at a time
    for (0..request.len) |i| {
        parser.feed(request[i .. i + 1]) catch |err| switch (err) {
            error.Paused => break, // Headers complete, parser paused - we're done
            else => return err,
        };
    }

    try std.testing.expectEqual(true, parser.state.has_method);
    try std.testing.expectEqual(.get, req.method);

    try std.testing.expectEqual(true, parser.state.has_version);
    try std.testing.expectEqual(1, req.version_major);
    try std.testing.expectEqual(1, req.version_minor);

    try std.testing.expectEqual(true, parser.state.has_url);
    try std.testing.expectEqualStrings("/example", req.url);

    try std.testing.expectEqual(true, parser.state.headers_complete);

    const host_val = req.headers.get("Host");
    try std.testing.expect(host_val != null);
    try std.testing.expectEqualStrings("example.com", host_val.?);
}

test "ResponseParser: basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var response: ParsedResponse = .{
        .arena = arena.allocator(),
    };

    var parser: ResponseParser = undefined;
    parser.init(&response);
    defer parser.deinit();

    const http_response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";

    // Feed the response 1 byte at a time
    for (0..http_response.len) |i| {
        parser.feed(http_response[i .. i + 1]) catch |err| switch (err) {
            error.Paused => break, // Headers complete, parser paused - we're done
            else => return err,
        };
    }

    try std.testing.expectEqual(true, parser.state.has_status);
    try std.testing.expectEqual(.ok, response.status);

    try std.testing.expectEqual(true, parser.state.has_version);
    try std.testing.expectEqual(1, response.version_major);
    try std.testing.expectEqual(1, response.version_minor);

    try std.testing.expectEqual(true, parser.state.headers_complete);

    const content_type = response.headers.get("Content-Type");
    try std.testing.expect(content_type != null);
    try std.testing.expectEqualStrings("text/plain", content_type.?);

    const content_length = response.headers.get("Content-Length");
    try std.testing.expect(content_length != null);
    try std.testing.expectEqualStrings("5", content_length.?);
}

test "ResponseParser: 404 status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var response: ParsedResponse = .{
        .arena = arena.allocator(),
    };

    var parser: ResponseParser = undefined;
    parser.init(&response);
    defer parser.deinit();

    const http_response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";

    parser.feed(http_response) catch |err| switch (err) {
        error.Paused => {},
        else => return err,
    };

    try std.testing.expectEqual(.not_found, response.status);
    try std.testing.expectEqual(1, response.version_major);
    try std.testing.expectEqual(1, response.version_minor);
}
