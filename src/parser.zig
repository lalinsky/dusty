const std = @import("std");

const c = @cImport({
    @cInclude("llhttp.h");
});

const Method = @import("http.zig").Method;
const Headers = @import("http.zig").Headers;
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

    fn saveCurrentHeader(self: *RequestParser) !void {
        if (self.state.current_header_field_start != null and self.state.current_header_value_start != null) {
            const field_start = self.state.current_header_field_start.?;
            const value_start = self.state.current_header_value_start.?;

            const field = field_start[0..self.state.current_header_field_len];
            const value = value_start[0..self.state.current_header_value_len];

            std.log.info("Header: {s} = {s}", .{ field, value });
            //try self.headers.put(self.allocator, field, value);

            // Reset for next header
            self.state.current_header_field_start = null;
            self.state.current_header_field_len = 0;
            self.state.current_header_value_start = null;
            self.state.current_header_value_len = 0;
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
        std.debug.assert(self.state.header_value.len > 0);

        self.request.headers.put(self.request.arena, self.state.header_field, self.state.header_value) catch return -1;

        self.state.header_value = "";
        self.state.header_field = "";
        self.state.has_header_field = false;

        return 0;
    }

    fn onHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
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

        // Continue - let parser run to completion or next callback
        return 0;
    }

    fn onMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.message_complete = true;
        // Pause so we can detect completion
        return c.HPE_PAUSED;
    }
};

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
