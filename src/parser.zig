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
    allocator: std.mem.Allocator,
    settings: c.llhttp_settings_t,
    parser: c.llhttp_t,
    state: State = .{},

    const State = struct {
        request: Request = .{},

        has_method: bool = false,
        has_version: bool = false,
        has_url: bool = false,

        // Temporary state for header parsing
        has_header_field: bool = false,
        header_field: []const u8 = "",
        header_value: []const u8 = "",

        headers_complete: bool = false,
        message_complete: bool = false,
    };

    pub fn init(self: *RequestParser, allocator: std.mem.Allocator) !void {
        self.* = .{
            .parser = undefined,
            .settings = undefined,
            .allocator = allocator,
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
        self.settings.on_message_complete = onMessageComplete;

        c.llhttp_init(&self.parser, c.HTTP_REQUEST, &self.settings);
    }

    pub fn deinit(self: *RequestParser) void {
        self.state.request.headers.deinit(self.allocator);
    }

    pub fn reset(self: *RequestParser) void {
        self.state.request.headers.deinit(self.allocator);
        self.state = .{};
        c.llhttp_reset(&self.parser);
    }

    pub fn feed(self: *RequestParser, data: []const u8) !void {
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);

        if (err != c.HPE_OK and err != c.HPE_PAUSED) {
            return mapError(err);
        }
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
        self.state.request.method = @enumFromInt(c.llhttp_get_method(&self.parser));
        return 0;
    }

    fn onVersion(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.has_version = true;
        self.state.request.version_major = c.llhttp_get_http_major(&self.parser);
        self.state.request.version_minor = c.llhttp_get_http_minor(&self.parser);
        return 0;
    }

    // Callbacks - store slices directly without copying
    fn onUrl(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.request.url, at, length);
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

        self.state.request.headers.put(self.allocator, self.state.header_field, self.state.header_value) catch return -1;

        self.state.header_value = "";
        self.state.header_field = "";
        self.state.has_header_field = false;

        return 0;
    }

    fn onHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.headers_complete = true;
        return 0;
    }

    fn onMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.message_complete = true;
        return 0;
    }
};

test "RequestParser: basic" {
    var parser: RequestParser = undefined;
    try parser.init(std.testing.allocator);
    defer parser.deinit();

    const request = "GET /example HTTP/1.1\r\nHost: example.com\r\n\r\n";

    // We will feed it the requst 1 byte at a time
    for (0..request.len) |i| {
        try parser.feed(request[i .. i + 1]);
    }
    try parser.finish();

    try std.testing.expectEqual(true, parser.state.has_method);
    try std.testing.expectEqual(.get, parser.state.request.method);

    try std.testing.expectEqual(true, parser.state.has_version);
    try std.testing.expectEqual(1, parser.state.request.version_major);
    try std.testing.expectEqual(1, parser.state.request.version_minor);

    try std.testing.expectEqual(true, parser.state.has_url);
    try std.testing.expectEqualStrings("/example", parser.state.request.url);

    try std.testing.expectEqual(true, parser.state.headers_complete);
    try std.testing.expectEqual(true, parser.state.message_complete);

    const host_val = parser.state.request.headers.get("Host");
    try std.testing.expect(host_val != null);
    try std.testing.expectEqualStrings("example.com", host_val.?);
}
