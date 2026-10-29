const std = @import("std");
const Transport = @import("transport.zig").Transport;

const c = @import("llhttp");
const zlib = @import("zlib");
const build_options = @import("build_options");

const Method = @import("http.zig").Method;
const Status = @import("http.zig").Status;
const Headers = @import("http.zig").Headers;
const ContentType = @import("http.zig").ContentType;
const ContentEncoding = @import("http.zig").ContentEncoding;
const Request = @import("request.zig").Request;

pub const ParseError = error{
    InvalidMethod,
    InvalidUrl,
    InvalidHeaderToken,
    InvalidHeaderValue,
    InvalidVersion,
    UnsupportedVersion,
    InvalidStatus,
    InvalidChunkSize,
    UnexpectedContentLength,
    ClosedConnection,
    TooManyHeaders,
    ChunkFramingTooLarge,
    InvalidHost,
    ParseFailed,
};

pub const FinishError = ParseError || error{IncompleteBody};

/// Tells the parser the stream ended. Only called from inside a body, so
/// an end the message was not ready for is a body cut short.
fn finishParser(parser: *c.llhttp_t) FinishError!void {
    const err = c.llhttp_finish(parser);
    // HPE_PAUSED means our on_message_complete callback fired and paused,
    // i.e. the message was completed by EOF (connection-close framing).
    if (err == c.HPE_OK or err == c.HPE_PAUSED) return;
    if (err == c.HPE_INVALID_EOF_STATE) return error.IncompleteBody;
    return mapError(err);
}

fn mapError(err: c.llhttp_errno_t) ParseError {
    return switch (err) {
        c.HPE_INVALID_METHOD => ParseError.InvalidMethod,
        c.HPE_INVALID_URL => ParseError.InvalidUrl,
        c.HPE_INVALID_HEADER_TOKEN => ParseError.InvalidHeaderToken,
        c.HPE_INVALID_VERSION => ParseError.InvalidVersion,
        c.HPE_INVALID_STATUS => ParseError.InvalidStatus,
        // llhttp reports a failing callback by its name, not by what the
        // callback returned. `onStatusComplete` only fails on a code
        // `Status` cannot name, so this is that.
        c.HPE_CB_STATUS_COMPLETE => ParseError.InvalidStatus,
        // Likewise: `onHeaderValueComplete` only fails when `Headers.add`
        // is out of room, or else through `RequestParser.State.err`.
        c.HPE_CB_HEADER_VALUE_COMPLETE => ParseError.TooManyHeaders,
        // And `RequestParser.onVersion` only on a major version other than 1,
        c.HPE_CB_VERSION_COMPLETE => ParseError.UnsupportedVersion,
        // `RequestParser.onHeadersComplete`, other than through `State.err`,
        // only on a request line with no version, which is HTTP/0.9,
        c.HPE_CB_HEADERS_COMPLETE => ParseError.UnsupportedVersion,
        // and `RequestParser.onProtocolComplete` only on a protocol other
        // than HTTP.
        c.HPE_CB_PROTOCOL_COMPLETE => ParseError.InvalidVersion,
        c.HPE_INVALID_CHUNK_SIZE => ParseError.InvalidChunkSize,
        c.HPE_UNEXPECTED_CONTENT_LENGTH => ParseError.UnexpectedContentLength,
        c.HPE_CLOSED_CONNECTION => ParseError.ClosedConnection,
        else => ParseError.ParseFailed,
    };
}

/// Chunked trailers come through the header callbacks too, but in the
/// middle of body reading, where the buffer is refilled under them and a
/// trailer split across two fills is delivered from two places. Nothing
/// exposes trailers, so the callbacks drop them.
fn inTrailers(parser: *const c.llhttp_t) bool {
    return parser.flags & @as(u16, @intCast(c.F_TRAILING)) != 0;
}

/// Chunked framing -- extensions, trailers, chunk-size lines -- is held to
/// this much at a time: each chunk earns `chunk_framing_allowance` back, but
/// the budget never grows past this. llhttp bounds none of it, and none of
/// it is body for `max_body_size` to count.
const max_chunk_framing = 16 * 1024;

/// What one chunk needs besides its data: up to 16 hex digits of size and
/// two CRLFs, with room to spare.
const chunk_framing_allowance = 32;

const FramingBudget = struct {
    left: usize = max_chunk_framing,
    /// Body bytes llhttp handed over during the current feed.
    body_len: usize = 0,
    /// Allowance earned by chunks that started during the current feed.
    earned: usize = 0,
    /// Sticky: llhttp is left mid-message, or paused at its end, and must not
    /// be fed again.
    err: ?ParseError = null,

    fn charge(self: *FramingBudget, parser: *const c.llhttp_t, data: []const u8, err: c.llhttp_errno_t) void {
        const consumed = if (err == c.HPE_OK) data.len else @intFromPtr(c.llhttp_get_error_pos(parser)) - @intFromPtr(data.ptr);
        const framing = consumed - self.body_len;
        // What a feed earns is spent before the cap applies, or a feed of
        // small chunks bigger than the budget would be refused.
        const available = self.left +| self.earned;
        if (framing > available) {
            self.err = error.ChunkFramingTooLarge;
            return;
        }
        self.left = @min(available - framing, max_chunk_framing);
    }
};

/// The flag is set as soon as the head says chunked, so on its own it would
/// charge the rest of a head that arrives in pieces.
fn inChunkedBody(parser: *const c.llhttp_t, headers_complete: bool) bool {
    return headers_complete and parser.flags & @as(u16, @intCast(c.F_CHUNKED)) != 0;
}

pub const RequestParser = struct {
    settings: c.llhttp_settings_t,
    parser: c.llhttp_t,
    request: *Request,
    state: State = .{},
    framing: FramingBudget = .{},

    const State = struct {
        has_method: bool = false,
        has_version: bool = false,
        has_url: bool = false,
        protocol: []const u8 = "",
        host: ?[]const u8 = null,
        absolute_form: bool = false,
        /// Set by a callback that fails for a reason llhttp's error code
        /// would misreport.
        err: ?ParseError = null,

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
        self.settings.on_protocol = onProtocol;
        self.settings.on_protocol_complete = onProtocolComplete;
        self.settings.on_version_complete = onVersion;
        self.settings.on_url = onUrl;
        self.settings.on_url_complete = onUrlComplete;
        self.settings.on_header_field = onHeaderField;
        self.settings.on_header_field_complete = onHeaderFieldComplete;
        self.settings.on_header_value = onHeaderValue;
        self.settings.on_header_value_complete = onHeaderValueComplete;
        self.settings.on_headers_complete = onHeadersComplete;
        self.settings.on_body = onBody;
        self.settings.on_chunk_header = onChunkHeader;
        self.settings.on_message_complete = onMessageComplete;

        c.llhttp_init(&self.parser, c.HTTP_REQUEST, &self.settings);
        // Any DIGIT "." DIGIT reaches `onVersion`, which judges it: llhttp
        // would reject HTTP/1.2, which RFC 9112 2.3 says to serve as 1.1,
        // and accept HTTP/2.0 and HTTP/0.9.
        c.llhttp_set_lenient_version(&self.parser, 1);
    }

    pub fn deinit(self: *RequestParser) void {
        _ = self;
    }

    pub fn reset(self: *RequestParser) void {
        self.state = .{};
        self.framing = .{};
        c.llhttp_reset(&self.parser);
    }

    pub fn feed(self: *RequestParser, data: []const u8) (ParseError || error{Paused})!void {
        if (self.framing.err) |e| return e;
        const chunked = inChunkedBody(&self.parser, self.state.headers_complete);
        self.framing.body_len = 0;
        self.framing.earned = 0;
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);
        if (chunked) self.framing.charge(&self.parser, data, err);
        if (self.framing.err) |e| return e;
        if (self.state.err) |e| return e;

        if (err == c.HPE_OK) {
            return;
        }

        if (err == c.HPE_PAUSED) {
            return error.Paused;
        }

        return mapError(err);
    }

    pub fn finish(self: *RequestParser) FinishError!void {
        if (self.framing.err) |e| return e;
        return finishParser(&self.parser);
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
        return self.state.message_complete and self.framing.err == null;
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

    fn onProtocol(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.protocol, at, length);
        return 0;
    }

    /// llhttp also takes RTSP and ICE in a request line.
    fn onProtocolComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        if (!std.mem.eql(u8, self.state.protocol, "HTTP")) return -1;
        return 0;
    }

    fn onVersion(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        if (c.llhttp_get_http_major(&self.parser) != 1) return -1;
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
        if (inTrailers(parser.?)) return 0;
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_field, at, length);
        return 0;
    }

    fn onHeaderFieldComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        if (inTrailers(parser.?)) return 0;
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        std.debug.assert(self.state.header_field.len > 0);
        self.state.has_header_field = true;
        return 0;
    }

    fn onHeaderValue(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        if (inTrailers(parser.?)) return 0;
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_value, at, length);
        return 0;
    }

    fn onHeaderValueComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        if (inTrailers(parser.?)) return 0;
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);

        std.debug.assert(self.state.has_header_field);

        if (std.ascii.eqlIgnoreCase(self.state.header_field, "Host")) {
            // llhttp keeps trailing whitespace, which RFC 9110 5.5 leaves
            // out of the field value.
            self.state.header_value = std.mem.trimEnd(u8, self.state.header_value, " \t");
            // RFC 9112 3.2: more than one Host, or an invalid one, is a 400.
            if (self.state.host != null or !isValidHost(self.state.header_value)) {
                self.state.err = error.InvalidHost;
                return -1;
            }
            self.state.host = self.state.header_value;
        }

        // Headers point directly into the read buffer, no copy needed
        self.request.headers.add(self.state.header_field, self.state.header_value) catch return -1;

        self.state.header_value = "";
        self.state.header_field = "";
        self.state.has_header_field = false;

        return 0;
    }

    fn onHeadersComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        if (!self.state.has_version) return -1;

        self.checkTarget() catch |err| {
            self.state.err = err;
            return -1;
        };

        if (self.request.headers.get("Content-Type")) |content_type| {
            self.request.content_type = ContentType.fromContentType(content_type);
        }

        if (self.request.headers.get("Content-Encoding")) |content_encoding| {
            self.request.content_encoding = ContentEncoding.fromString(content_encoding);
        }

        if (self.request.headers.get("Content-Length")) |content_length| {
            self.request.content_length = std.fmt.parseInt(usize, content_length, 10) catch null;
        }

        self.state.headers_complete = true;
        return c.HPE_PAUSED; // Always pause so we can track consumed bytes
    }

    /// Checks Host against the target. RFC 9112 3.2.2: an absolute-form
    /// target is routed by its path and query, and its authority takes the
    /// place of Host. An empty path is left for `parseHeaders` to make "/",
    /// which may take an allocation.
    fn checkTarget(self: *RequestParser) ParseError!void {
        // RFC 9112 3.2: HTTP/1.0 may leave Host out, HTTP/1.1 may not.
        if (self.state.host == null and self.request.version_minor >= 1) return error.InvalidHost;
        const empty_host = if (self.state.host) |host| host.len == 0 else false;
        const url = self.request.url;
        if (self.request.method == .connect) {
            // RFC 9112 3.2: Host is empty only for a target with no authority.
            if (empty_host) return error.InvalidHost;
            return;
        }
        if (url.len == 0 or url[0] == '/' or url[0] == '*') return;

        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
        const rest = url[scheme_end + 3 ..];
        const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..authority_end];
        // RFC 9110 4.2.1 and 4.2.4: an http(s) authority has a host and no
        // userinfo.
        if (authority.len == 0 or !isValidHost(authority)) return error.InvalidUrl;
        if (empty_host) return error.InvalidHost;
        self.request.headers.put("Host", authority) catch return error.TooManyHeaders;
        self.state.absolute_form = true;
        self.request.url = rest[authority_end..];
    }

    fn onBody(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.framing.body_len += length;

        const available = self.state.body_dest_buf.len - self.state.body_dest_pos;
        const to_copy = @min(length, available);

        if (to_copy > 0) {
            @memcpy(self.state.body_dest_buf[self.state.body_dest_pos..][0..to_copy], at[0..to_copy]);
            self.state.body_dest_pos += to_copy;
        }

        return 0;
    }

    fn onChunkHeader(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.framing.earned +|= chunk_framing_allowance;
        return 0;
    }

    fn onMessageComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *RequestParser = @fieldParentPtr("parser", parser.?);
        self.state.message_complete = true;
        // Pause so we can detect completion
        return c.HPE_PAUSED;
    }
};

/// RFC 9112 3.2: `uri-host [ ":" port ]`, with uri-host an IP-literal or a
/// reg-name (which an IPv4address also is) as in RFC 3986 3.2.2. The
/// brackets of an IP-literal are checked for its characters only. Empty
/// is valid here; whether it is allowed depends on the target.
fn isValidHost(value: []const u8) bool {
    if (value.len == 0) return true;
    var port: []const u8 = undefined;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        if (close == 1) return false;
        for (value[1..close]) |ch| {
            if (!isUnreserved(ch) and !isSubDelim(ch) and ch != ':') return false;
        }
        port = value[close + 1 ..];
        if (port.len > 0) {
            if (port[0] != ':') return false;
            port = port[1..];
        }
    } else {
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse value.len;
        if (colon == 0) return false;
        var i: usize = 0;
        while (i < colon) : (i += 1) {
            const ch = value[i];
            if (ch == '%') {
                if (i + 2 >= colon or !std.ascii.isHex(value[i + 1]) or !std.ascii.isHex(value[i + 2])) return false;
                i += 2;
            } else if (!isUnreserved(ch) and !isSubDelim(ch)) return false;
        }
        port = if (colon < value.len) value[colon + 1 ..] else "";
    }
    for (port) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

fn isSubDelim(ch: u8) bool {
    return switch (ch) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

/// Minimal struct for holding parsed HTTP response data.
/// Used by ResponseParser to store parsed fields.
pub const ParsedResponse = struct {
    status: Status = .ok,
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: Headers = .{},
    content_type: ?ContentType = null,
    content_encoding: ContentEncoding = .identity,
    content_length: ?usize = null,
    arena: std.mem.Allocator,
};

/// HTTP response parser using llhttp.
/// Mirrors RequestParser but parses HTTP responses instead of requests.
pub const ResponseParser = struct {
    settings: c.llhttp_settings_t,
    parser: c.llhttp_t,
    response: *ParsedResponse,
    max_headers: usize,
    state: State = .{},
    framing: FramingBudget = .{},
    /// The request was HEAD, so the response has no body whatever its
    /// headers say. llhttp cannot tell from the response alone.
    head_request: bool = false,
    /// The request was CONNECT, so a 2xx response has no body: the
    /// connection is a tunnel from the end of the head.
    connect_request: bool = false,

    const State = struct {
        has_status: bool = false,
        has_version: bool = false,

        // Temporary state for header parsing
        has_header_field: bool = false,
        header_field: []const u8 = "",
        header_value: []const u8 = "",

        headers_complete: bool = false,
        message_complete: bool = false,
        // Set by a failed `feed` or `finish`. llhttp keeps no record of an
        // end-of-stream the message was not ready for.
        failed: bool = false,
        // An interim response was read and dropped on the way to this one.
        saw_interim: bool = false,

        // Body reading state
        body_dest_buf: []u8 = &.{}, // Where onBody should copy to
        body_dest_pos: usize = 0, // How much onBody has written
    };

    pub fn init(self: *ResponseParser, response: *ParsedResponse, max_headers: usize) !void {
        self.* = .{
            .parser = undefined,
            .settings = undefined,
            .response = response,
            .max_headers = max_headers,
        };
        response.headers = try Headers.init(response.arena, max_headers);

        self.settings = std.mem.zeroes(c.llhttp_settings_t);
        self.settings.on_status_complete = onStatusComplete;
        self.settings.on_version_complete = onVersion;
        self.settings.on_header_field = onHeaderField;
        self.settings.on_header_field_complete = onHeaderFieldComplete;
        self.settings.on_header_value = onHeaderValue;
        self.settings.on_header_value_complete = onHeaderValueComplete;
        self.settings.on_headers_complete = onHeadersComplete;
        self.settings.on_body = onBody;
        self.settings.on_chunk_header = onChunkHeader;
        self.settings.on_message_complete = onMessageComplete;

        c.llhttp_init(&self.parser, c.HTTP_RESPONSE, &self.settings);
    }

    pub fn deinit(self: *ResponseParser) void {
        _ = self;
    }

    pub fn reset(self: *ResponseParser) void {
        self.state = .{};
        self.framing = .{};
        c.llhttp_reset(&self.parser);
    }

    /// Forgets the message parsed so far and starts on the next one in the
    /// stream: the final response behind an interim one.
    pub fn restart(self: *ResponseParser) !void {
        self.response.* = .{ .arena = self.response.arena };
        self.response.headers = try Headers.init(self.response.arena, self.max_headers);
        self.reset();
        self.state.saw_interim = true;
    }

    pub fn feed(self: *ResponseParser, data: []const u8) !void {
        if (self.framing.err) |e| return e;
        const chunked = inChunkedBody(&self.parser, self.state.headers_complete);
        self.framing.body_len = 0;
        self.framing.earned = 0;
        const err = c.llhttp_execute(&self.parser, data.ptr, data.len);
        if (chunked) self.framing.charge(&self.parser, data, err);
        if (self.framing.err) |e| {
            self.state.failed = true;
            return e;
        }

        if (err == c.HPE_OK) {
            return;
        }

        if (err == c.HPE_PAUSED) {
            return error.Paused;
        }

        self.state.failed = true;
        return mapError(err);
    }

    pub fn finish(self: *ResponseParser) FinishError!void {
        errdefer self.state.failed = true;
        if (self.framing.err) |e| return e;
        return finishParser(&self.parser);
    }

    pub fn hasFailed(self: *const ResponseParser) bool {
        return self.state.failed;
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
        return self.state.message_complete and self.framing.err == null;
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
        // llhttp accepts any three digit code, but `Status` only names the
        // ones llhttp knows, and `@enumFromInt` on the rest is illegal
        // behaviour. Reject here rather than store a value that cannot be
        // switched on and whose `name()` aborts inside llhttp.
        const code = std.math.cast(u16, c.llhttp_get_status_code(&self.parser)) orelse return -1;
        const status = Status.fromCode(code) catch return -1;
        self.state.has_status = true;
        self.response.status = status;
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
        if (inTrailers(parser.?)) return 0;
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_field, at, length);
        return 0;
    }

    fn onHeaderFieldComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        if (inTrailers(parser.?)) return 0;
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        std.debug.assert(self.state.header_field.len > 0);
        self.state.has_header_field = true;
        return 0;
    }

    fn onHeaderValue(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        if (inTrailers(parser.?)) return 0;
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        appendSlice(&self.state.header_value, at, length);
        return 0;
    }

    fn onHeaderValueComplete(parser: ?*c.llhttp_t) callconv(.c) c_int {
        if (inTrailers(parser.?)) return 0;
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);

        std.debug.assert(self.state.has_header_field);

        // Headers point directly into arena-allocated read buffer, no copy needed
        self.response.headers.add(self.state.header_field, self.state.header_value) catch return -1;

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

        if (self.response.headers.get("Content-Encoding")) |content_encoding| {
            self.response.content_encoding = ContentEncoding.fromString(content_encoding);
        }

        if (self.response.headers.get("Content-Length")) |content_length| {
            self.response.content_length = std.fmt.parseInt(usize, content_length, 10) catch null;
        }

        // Returning 1 is how a callback normally asks llhttp to skip the
        // body, but this one has to return HPE_PAUSED, so set the flag it
        // would have set.
        const tunnel = self.connect_request and @intFromEnum(self.response.status) / 100 == 2;
        if (self.head_request or tunnel) self.parser.flags |= @intCast(c.F_SKIPBODY);

        self.state.headers_complete = true;
        return c.HPE_PAUSED; // Always pause so we can track consumed bytes
    }

    fn onBody(parser: ?*c.llhttp_t, at: [*c]const u8, length: usize) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        self.framing.body_len += length;

        const available = self.state.body_dest_buf.len - self.state.body_dest_pos;
        const to_copy = @min(length, available);

        if (to_copy > 0) {
            @memcpy(self.state.body_dest_buf[self.state.body_dest_pos..][0..to_copy], at[0..to_copy]);
            self.state.body_dest_pos += to_copy;
        }

        return 0;
    }

    fn onChunkHeader(parser: ?*c.llhttp_t) callconv(.c) c_int {
        const self: *ResponseParser = @fieldParentPtr("parser", parser.?);
        self.framing.earned +|= chunk_framing_allowance;
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
/// - `feed(data: []const u8) (ParseError || error{Paused})!void`
/// - `finish() ParseError!void`
/// - `getConsumedBytes(ptr: [*c]const u8) usize`
///
/// `feed` and `finish` must fail within `ParseError`, because what they
/// return ends up in `err` and from there in the error set of every public
/// body read. A parser free to invent its own errors would put its internals
/// in that set -- `Paused` included, which is signalling between the parser
/// and this loop and means nothing to a caller.
///
/// Read through `interface` and find out what a failed read was from `err`,
/// the same way the response body writers work. Passed around by value: it
/// holds an interface and pointers, and nothing points back at it.
///
/// Both transforms between wire bytes and the body a caller asked for are
/// this type's job. It undoes the transfer framing itself; for a content
/// coding it stacks, because `zlib.Decompress` reads from a
/// `std.Io.Reader` and so needs one underneath it handing over raw framed
/// bytes. That one is another `BodyReader` -- same type, lower role -- and
/// `startDecoding` puts it and the decoder in one allocation.
pub fn BodyReader(comptime Parser: type) type {
    return struct {
        parser: *Parser,
        transport: Transport,
        request: ?*Request = null,
        /// Set when the headers called for a content coding. Null both when
        /// nothing is coded and on the lower reader that feeds the decoder.
        decode: ?*Decode = null,
        interface: std.Io.Reader,
        /// The real cause behind the generic `error.ReadFailed` that the
        /// `std.Io.Reader` interface has to return. `stream` is the one path
        /// that cannot hand a cause back, its error set being fixed by the
        /// vtable, so it is the one place this is written.
        ///
        /// Not every cause is the transport's. A body that stops mid-chunk,
        /// framing the parser rejects, or a corrupt deflate stream fails the
        /// read just as surely and the connection has nothing to say about
        /// it.
        err: ?Error = null,

        const Self = @This();

        comptime {
            // Stated above, checked here: a parser outside `ParseError` would
            // otherwise fail somewhere inside `stream` with no hint as to why.
            assertFailsWithin(@TypeOf(Parser.feed), ParseError || error{Paused});
            assertFailsWithin(@TypeOf(Parser.finish), FinishError);
        }

        /// What the decoder recorded, said in terms a caller can act on.
        /// Switched on rather than compared so what it rewrites drops out of
        /// the inferred error set as well as out of the answer, the same way
        /// tls.zig's `ReadFailed` does in `Transport`.
        fn decodeCause(e: zlib.Decompress.Error) !void {
            switch (e) {
                // The reader below it failed, and that reader knows why:
                // keep descending.
                error.ReadFailed => {},
                // The compressed stream stopped early -- the same condition
                // the framing half reports as `IncompleteBody`, and the same
                // name is what it needs.
                error.TruncatedInput => return error.IncompleteBody,
                else => |cause| return cause,
            }
        }

        /// What reading a body can fail with, once the sentinel is resolved.
        pub const Error = Transport.ReadError || Transport.WriteError ||
            ParseError || @typeInfo(@TypeOf(decodeCause(undefined))).error_union.error_set ||
            error{ IncompleteBody, Unexpected };

        /// Stores what actually went wrong and reports the sentinel the
        /// vtable requires. Mirrors `fail` on the buffered body writer.
        fn fail(self: *Self, cause: Error) std.Io.Reader.StreamError {
            self.err = cause;
            return error.ReadFailed;
        }

        pub fn init(parser: *Parser, transport: Transport, buffer: []u8) Self {
            return .{
                .parser = parser,
                .transport = transport,
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        /// The decoder and the reader handing it raw framed bytes, in one
        /// allocation so the pointers between them stay put while the body
        /// reader above is copied around by value. zlib's own state is
        /// allocated from the same allocator when decoding starts.
        pub const Decode = struct {
            source: Self,
            source_buffer: [source_buffer_len]u8,
            decoder: zlib.Decompress,

            /// What the decoder pulls raw framed bytes in. It takes all of
            /// it at once, so this is about how often that goes back through
            /// the parser, not about correctness.
            const source_buffer_len = 4096;
        };

        pub const StartDecodingError = std.mem.Allocator.Error ||
            error{UnsupportedContentEncoding};

        /// Undo `encoding` as the body is read, so `interface` yields the
        /// representation the message was about rather than the one it was
        /// shipped in. `.identity` is a no-op, and an encoding we cannot
        /// undo is refused rather than guessed at.
        ///
        /// Call once, on a reader that has not been read from: what it is
        /// now is copied down to become the reader underneath, and its
        /// buffer position is copied with it.
        ///
        /// Allocated rather than inline because the decoder reads from the
        /// reader underneath by pointer, and a body reader is embedded in
        /// `Request` and in `ClientResponse` and copied around by value; zlib
        /// allocates its window, sized to the stream, only once decoding
        /// starts. It lives as long as the reader does; both callers hand
        /// over a per-message arena, so nothing here is freed.
        pub fn startDecoding(
            self: *Self,
            allocator: std.mem.Allocator,
            encoding: ContentEncoding,
        ) StartDecodingError!void {
            // Built without zlib, nothing here can undo a coding.
            if (!build_options.use_zlib and encoding != .identity) return error.UnsupportedContentEncoding;
            const container: zlib.Container = switch (encoding) {
                .identity => return,
                .gzip => .gzip,
                // HTTP's "deflate" is zlib-wrapped, whatever the name says.
                .deflate => .zlib,
                .unknown => return error.UnsupportedContentEncoding,
            };
            // Stated above, checked here. A reader that has been read from
            // would carry positions into the caller's buffer down into a
            // copy whose buffer is `source_buffer`, and they would mean
            // something else there.
            std.debug.assert(self.decode == null);
            std.debug.assert(self.interface.seek == self.interface.end);

            const decode = try allocator.create(Decode);
            decode.source = self.*;
            decode.source.interface.buffer = &decode.source_buffer;
            // No buffer of its own: it is only ever read through `stream`,
            // which writes into the caller's writer.
            decode.decoder = try .init(allocator, &decode.source.interface, &.{}, container, .{});
            self.decode = decode;
        }

        /// Pulls decoded bytes from the decoder, and on failure descends to
        /// whichever layer knows why: the decoder itself, then the reader
        /// under it, which has already resolved through the transport.
        fn streamDecoded(
            self: *Self,
            decode: *Decode,
            w: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            return decode.decoder.reader.stream(w, limit) catch |err| switch (err) {
                error.ReadFailed => {
                    if (decode.decoder.err) |e| {
                        if (decodeCause(e)) |_| {} else |cause| return self.fail(cause);
                    }
                    return self.fail(decode.source.err orelse error.Unexpected);
                },
                else => |e| return e,
            };
        }

        fn stream(io_r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", io_r));
            if (self.decode) |decode| return self.streamDecoded(decode, w, limit);
            return self.streamFramed(w, limit);
        }

        fn streamFramed(self: *Self, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const parser = self.parser;
            const conn = self.transport.reader;

            // Send 100 Continue on first body read if client expects it
            if (self.request) |req| {
                if (req.expects_continue) {
                    if (req.response) |res| {
                        // A final response has started, and 100 can no
                        // longer precede it. The peer may still be holding
                        // the body, so the flag stays.
                        if (!res.headers_written) {
                            req.expects_continue = false;
                            // A write, on a read: the caller asked for the body
                            // and this is what unblocks the peer from sending it.
                            sendContinue(res.conn.writer) catch
                                return self.fail(self.transport.getWriteError() orelse error.Unexpected);
                        }
                    }
                }
            }

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
                            parser.finish() catch |e| return self.fail(e);

                            // Check if body is now complete after finish()
                            if (parser.isBodyComplete()) {
                                return error.EndOfStream;
                            }

                            // The peer stopped mid-body. Nothing is wrong with
                            // the connection, so it has no cause to offer.
                            return self.fail(error.IncompleteBody);
                        },
                        error.ReadFailed => return self.fail(
                            self.transport.getReadError() orelse error.Unexpected,
                        ),
                    };
                }

                // Get buffered data
                const buffered = conn.buffered();
                if (buffered.len == 0) {
                    return 0;
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
                        // Framing the parser rejected: the bytes arrived, they
                        // just were not a body.
                        else => |e| return self.fail(e),
                    }
                }

                // Continue loop to check if we got body bytes now
            }
        }
    };
}

/// BodyReader specialized for HTTP requests.
/// Fails to compile unless every error `Fn` can return is in `Allowed`.
fn assertFailsWithin(comptime Fn: type, comptime Allowed: type) void {
    const returned = @typeInfo(@typeInfo(Fn).@"fn".return_type.?).error_union.error_set;
    for (std.meta.fieldNames(returned)) |name| {
        // A member of `Allowed` coerces; anything else is a compile error
        // naming the offending parser and error.
        const member: Allowed = @field(Allowed, name);
        _ = &member;
    }
}

fn sendContinue(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    return w.flush();
}

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
        .transport = undefined,
        // Allocated by `parseHeaders`, which this test goes around.
        .headers = try Headers.init(arena.allocator(), 32),
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
    try parser.init(&response, 64);
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
    try parser.init(&response, 64);
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

test "ResponseParser: rejects a status code Status cannot name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var response: ParsedResponse = .{
        .arena = arena.allocator(),
    };

    var parser: ResponseParser = undefined;
    try parser.init(&response, 64);
    defer parser.deinit();

    // llhttp is happy with any three digits, so without the check in
    // onStatusComplete this reached @enumFromInt and took the process down.
    try std.testing.expectError(
        error.InvalidStatus,
        parser.feed("HTTP/1.1 250 Weird\r\nContent-Length: 0\r\n\r\n"),
    );
    try std.testing.expectEqual(false, parser.state.has_status);
}
