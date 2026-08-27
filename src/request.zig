const std = @import("std");

const http = @import("http.zig");
const RequestParser = @import("parser.zig").RequestParser;
const RequestBodyReader = @import("parser.zig").RequestBodyReader;
const Transport = @import("transport.zig").Transport;
const ParseError = @import("parser.zig").ParseError;
const ServerConfig = @import("config.zig").ServerConfig;
const body_read_reserve = @import("config.zig").body_read_reserve;
const Response = @import("response.zig").Response;
pub const Cookie = @import("cookie.zig").Cookie;
pub const SessionData = @import("middleware/Session.zig").SessionData;

pub const Request = struct {
    method: http.Method = undefined,
    url: []const u8 = "",
    version_major: u8 = 0,
    version_minor: u8 = 0,
    headers: http.Headers = .{},
    content_type: ?http.ContentType = null,
    /// The coding the body arrived in. Undone by the body reader unless
    /// `config.decompress` is off, in which case reading the body yields
    /// what the wire carried.
    content_encoding: http.ContentEncoding = .identity,
    params: http.Params = .{},
    query: http.Params = .{},
    /// The peer this request arrived from. A Unix socket peer has no
    /// address of its own and is reported as IPv4 loopback, which is what
    /// both zio and `std.Io.Threaded` substitute on accept.
    remote_address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) },

    arena: std.mem.Allocator,
    io: std.Io = undefined,

    // Installed by the server for real requests. Kept as a callback so this
    // module does not depend on the server's backend-specific timer type.
    _timeout_context: ?*anyopaque = null,
    _set_timeout: ?*const fn (*anyopaque, std.Io, std.Io.Timeout) void = null,

    // Body reading support
    parser: *RequestParser,
    transport: Transport,
    config: ServerConfig.Request = .{},
    _body: ?[]const u8 = null,
    _body_read: bool = false,
    // Set up on the first body read that calls for decoding, and kept so a
    // second `reader()` does not build a second decoder over the same body.
    _decode: ?*RequestBodyReader.Decode = null,
    _body_reader_taken: bool = false,
    _fd: std.StringHashMapUnmanaged([]const u8) = .{},
    _fd_read: bool = false,
    _mfd: std.StringHashMapUnmanaged(MultipartForm.Entry) = .{},
    _mfd_read: bool = false,
    session: SessionData = .{},

    // 100-continue support
    response: ?*Response = null,
    expects_continue: bool = false,

    pub fn reset(self: *Request) void {
        const arena = self.arena;
        const io = self.io;
        const parser = self.parser;
        const transport = self.transport;
        const cfg = self.config;
        const res = self.response;
        const timeout_context = self._timeout_context;
        const set_timeout = self._set_timeout;
        // Belongs to the connection, not the request, so it outlives the
        // reset the way the reader and the parser do.
        const addr = self.remote_address;
        self.* = .{
            .arena = arena,
            .io = io,
            .parser = parser,
            .transport = transport,
            .config = cfg,
            .response = res,
            .remote_address = addr,
            ._timeout_context = timeout_context,
            ._set_timeout = set_timeout,
        };
    }

    /// Replaces the deadline for this request. A duration starts now, a
    /// deadline is absolute, and `.none` disables the deadline. The server
    /// installs its normal keepalive deadline after the handler returns.
    ///
    /// Call from the connection's handler task, not concurrently from a task
    /// spawned by the handler.
    pub fn setTimeout(self: *Request, timeout: std.Io.Timeout) void {
        const set = self._set_timeout orelse return;
        set(self._timeout_context.?, self.io, timeout);
    }

    /// The request body: transfer framing undone, and the content coding
    /// too unless `config.decompress` is off. Read through `.interface`,
    /// and `.err` says what an `error.ReadFailed` from it actually was.
    ///
    /// `buffer` is where bytes wait between the connection and the caller,
    /// the way `Response.stream` takes one for the other direction. It is
    /// what `peek` and the `take` family read out of, so size it for the
    /// longest thing they need to see at once; an empty slice is fine for a
    /// caller that only ever streams.
    ///
    /// One per body. `body` takes it if you have not, so a handler that
    /// streams cannot then ask for the body whole.
    pub fn reader(self: *Request, buffer: []u8) !RequestBodyReader {
        var r = RequestBodyReader.init(self.parser, self.transport, buffer);

        // Once the body is in memory there is nothing left on the wire, and
        // what is cached has already been decoded.
        if (self._body_read) {
            r.interface = .fixed(self._body orelse &.{});
            return r;
        }

        // The buffer belongs to the caller, so a second reader starts empty
        // and whatever the first one had buffered is unreachable -- bytes off
        // the body, with nothing to say they went missing.
        std.debug.assert(!self._body_reader_taken); // one body reader per request
        self._body_reader_taken = true;

        r.request = self;
        if (self._decode) |decode| {
            r.decode = decode;
        } else if (self.config.decompress) {
            try r.startDecoding(self.arena, self.content_encoding);
            self._decode = r.decode;
        }
        return r;
    }

    /// Read the entire body into memory. Result is cached for subsequent calls.
    pub fn body(self: *Request) !?[]const u8 {
        if (self._body_read) {
            return self._body;
        }

        // Nothing to stage: `allocRemaining` streams straight into the arena.
        var no_buf: [0]u8 = .{};
        var r = try self.reader(&no_buf);
        const result = r.interface.allocRemaining(self.arena, .limited(self.config.max_body_size)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooBig,
            // The interface can only say that a read failed; the reader
            // holds what it was.
            error.ReadFailed => return r.err orelse error.Unexpected,
            else => |e| return e,
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

    /// Get cookies from the request
    pub fn cookies(self: *const Request) Cookie {
        return .{
            .header = self.headers.get("Cookie") orelse "",
        };
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
            if (self._fd.count() >= self.config.max_form_count) {
                return error.TooManyFormFields;
            }

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

    /// Parse the body as a multipart form (multipart/form-data)
    pub fn multiFormData(self: *Request) !*std.StringHashMapUnmanaged(MultipartForm.Entry) {
        if (self._mfd_read) {
            return &self._mfd;
        }

        if (self.content_type == null or self.content_type != .multipart_form) {
            return error.NotMultipartForm;
        }

        const buffer = try self.body() orelse {
            self._mfd_read = true;

            return &self._mfd;
        };

        // The following chunk of code is from https://github.com/karlseguin/http.zig, see LICENSE for more details.

        var boundary_buf: [72]u8 = undefined;
        const boundary = blk: {
            const directive = (self.headers.get("Content-Type") orelse unreachable)["multipart/form-data".len..];
            for (directive, 0..) |b, i| loop: {
                if (b != ' ' and b != ';') {
                    if (std.ascii.startsWithIgnoreCase(directive[i..], "boundary=")) {
                        const raw_boundary = directive["boundary=".len + i ..];
                        if (raw_boundary.len > 0 and raw_boundary.len <= 70) {
                            boundary_buf[0] = '-';
                            boundary_buf[1] = '-';
                            if (raw_boundary[0] == '"') {
                                if (raw_boundary.len > 2 and raw_boundary[raw_boundary.len - 1] == '"') {
                                    // it's really -2, since we need to strip out the two quotes
                                    // but buf is already at + 2, so they cancel out.
                                    const end = raw_boundary.len;
                                    @memcpy(boundary_buf[2..end], raw_boundary[1 .. raw_boundary.len - 1]);
                                    break :blk boundary_buf[0..end];
                                }
                            } else {
                                const end = 2 + raw_boundary.len;
                                @memcpy(boundary_buf[2..end], raw_boundary);
                                break :blk boundary_buf[0..end];
                            }
                        }
                    }
                    // not valid, break out of the loop so we can return
                    // an error.InvalidMultiPartFormDataHeader
                    break :loop;
                }
            }
            return error.InvalidMultiPartFormDataHeader;
        };

        var entry_it = std.mem.splitSequence(u8, buffer, boundary);

        {
            // We expect the body to begin with a boundary
            const first = entry_it.next() orelse {
                self._mfd_read = true;
                return &self._mfd;
            };
            if (first.len != 0) {
                return error.InvalidMultiPartEncoding;
            }
        }

        while (entry_it.next()) |entry| {
            // body ends with -- after a final boundary
            if (entry.len == 4 and entry[0] == '-' and entry[1] == '-' and entry[2] == '\r' and entry[3] == '\n') {
                break;
            }

            if (self._mfd.count() >= self.config.max_multiform_count) {
                return error.TooManyMultiFormFields;
            }

            if (entry.len < 2 or entry[0] != '\r' or entry[1] != '\n') return error.InvalidMultiPartEncoding;

            // [2..] to skip our boundary's trailing line terminator
            const field = try MultipartForm.parseMultiPartEntry(entry[2..]);
            try self._mfd.put(self.arena, field.name, field.value);
        }

        // End of chunk.

        self._mfd_read = true;

        return &self._mfd;
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

const MultipartForm = struct {
    const Entry = struct { value: []const u8, filename: ?[]const u8 = null };

    // The following chunk of code is from https://github.com/karlseguin/http.zig, see LICENSE for more details.

    const Field = struct {
        name: []const u8,
        value: Entry,
    };

    fn parseMultiPartEntry(entry: []const u8) !Field {
        var pos: usize = 0;
        var attributes: ?ContentDispositionAttributes = null;

        while (true) {
            const end_line_pos = std.mem.indexOfScalarPos(u8, entry, pos, '\n') orelse return error.InvalidMultiPartEncoding;
            const line = entry[pos..end_line_pos];

            pos = end_line_pos + 1;
            if (line.len == 0 or line[line.len - 1] != '\r') return error.InvalidMultiPartEncoding;

            if (line.len == 1) {
                break;
            }

            // we need to look for the name
            if (std.ascii.startsWithIgnoreCase(line, "content-disposition:") == false) {
                continue;
            }

            const value = trimLeadingSpace(line["content-disposition:".len..]);
            if (std.ascii.startsWithIgnoreCase(value, "form-data;") == false) {
                return error.InvalidMultiPartEncoding;
            }

            // constCast is safe here because we know this ultimately comes from one of our buffers
            const value_start = "form-data;".len;
            const value_end = value.len - 1; // remove the trailing \r
            attributes = try getContentDispositionAttributes(@constCast(trimLeadingSpace(value[value_start..value_end])));
        }

        const value = entry[pos..];
        if (value.len < 2 or value[value.len - 2] != '\r' or value[value.len - 1] != '\n') {
            return error.InvalidMultiPartEncoding;
        }

        const attr = attributes orelse return error.InvalidMultiPartEncoding;

        return .{
            .name = attr.name,
            .value = .{
                .value = value[0 .. value.len - 2],
                .filename = attr.filename,
            },
        };
    }

    const ContentDispositionAttributes = struct {
        name: []const u8,
        filename: ?[]const u8 = null,
    };

    fn getContentDispositionAttributes(fields: []u8) !ContentDispositionAttributes {
        var pos: usize = 0;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;

        while (pos < fields.len) {
            {
                const b = fields[pos];
                if (b == ';' or b == ' ' or b == '\t') {
                    pos += 1;
                    continue;
                }
            }

            const sep = std.mem.indexOfScalarPos(u8, fields, pos, '=') orelse return error.InvalidMultiPartEncoding;
            const field_name = fields[pos..sep];

            // skip the equal
            const value_start = sep + 1;
            if (value_start == fields.len) {
                return error.InvalidMultiPartEncoding;
            }

            var value: []const u8 = undefined;
            if (fields[value_start] != '"') {
                // Search from value_start, not pos: a stray ';' inside the
                // field name (malformed input the parser doesn't reject)
                // would otherwise place value_end before value_start.
                const value_end = std.mem.indexOfScalarPos(u8, fields, value_start, ';') orelse fields.len;
                pos = value_end;
                value = fields[value_start..value_end];
            } else blk: {
                // skip the double quote
                pos = value_start + 1;
                var write_pos = pos;
                while (pos < fields.len) {
                    switch (fields[pos]) {
                        '\\' => {
                            // Trailing backslash with no character to escape.
                            if (pos + 1 >= fields.len) {
                                return error.InvalidMultiPartEncoding;
                            }
                            // supposedly MSIE doesn't always escape \, so if the \ isn't escape
                            // one of the special characters, it must be a single \. This is what Go does.
                            switch (fields[pos + 1]) {
                                // from Go's mime parser func isTSpecial(r rune) bool
                                '(', ')', '<', '>', '@', ',', ';', ':', '"', '/', '[', ']', '?', '=' => |n| {
                                    fields[write_pos] = n;
                                    pos += 1;
                                },
                                else => fields[write_pos] = '\\',
                            }
                        },
                        '"' => {
                            pos += 1;
                            value = fields[value_start + 1 .. write_pos];
                            break :blk;
                        },
                        else => |b| fields[write_pos] = b,
                    }
                    pos += 1;
                    write_pos += 1;
                }
                return error.InvalidMultiPartEncoding;
            }

            if (std.mem.eql(u8, field_name, "name")) {
                name = value;
            } else if (std.mem.eql(u8, field_name, "filename")) {
                filename = value;
            }
        }

        return .{
            .name = name orelse return error.InvalidMultiPartEncoding,
            .filename = filename,
        };
    }

    inline fn trimLeadingSpaceCount(in: []const u8) struct { []const u8, usize } {
        if (in.len > 1 and in[0] == ' ') {
            // very common case
            const n = in[1];
            if (n != ' ' and n != '\t') {
                return .{ in[1..], 1 };
            }
        }

        for (in, 0..) |b, i| {
            if (b != ' ' and b != '\t') return .{ in[i..], i };
        }
        return .{ "", in.len };
    }

    inline fn trimLeadingSpace(in: []const u8) []const u8 {
        const out, _ = trimLeadingSpaceCount(in);
        return out;
    }

    // End of chunk.
};

const ParseHeadersError = std.Io.Reader.Error || ParseError ||
    error{ IncompleteRequest, HeadersTooLarge, OutOfMemory };

/// Parse HTTP headers from a reader and prepare for body reading.
///
/// The head is bounded by `reader.buffer`, less `body_read_reserve`: it is
/// never tossed while it is being parsed, because the header slices point
/// into it, so whatever it does not use is all the body reader will have.
/// A head is accepted exactly when it fits in that much.
///
/// Returns error.EndOfStream if connection closed cleanly with no data.
/// Returns error.IncompleteRequest if connection closed mid-request.
/// Returns error.HeadersTooLarge if the head does not fit.
pub fn parseHeaders(reader: *std.Io.Reader, parser: *RequestParser) ParseHeadersError!void {
    // Re-pre-allocate headers each call to handle keep-alive (arena was reset).
    parser.request.headers = try http.Headers.init(parser.request.arena, parser.request.config.max_header_count);
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
                else => |e| return e,
            };
            parsed_len += unparsed.len;
            continue;
        }
        // Every buffered byte has been consumed as head and it is still
        // open, so filling again is the only way forward -- and doing so
        // would eat into the reserve. `fillMore` on a buffer with no room
        // asks its rebase to free a byte that nothing can free, and asserts.
        if (reader.buffer.len - reader.end < body_read_reserve) return error.HeadersTooLarge;
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                if (parsed_len == 0) return error.EndOfStream;
                return error.IncompleteRequest;
            },
            else => |e| return e,
        };
    }
    // A fill is free to use every byte it was given room for, so a head can
    // still finish inside the reserve even though the check above passed
    // each time it ran. What is left is all the body reader gets, and
    // `BodyReader.stream` can no more fill a zero-length buffer than the
    // loop above could -- so the head is over the limit either way.
    if (reader.buffer.len - parsed_len < body_read_reserve) return error.HeadersTooLarge;

    reader.toss(parsed_len);
    parser.resumeParsing();

    // Shorten buffer so body reading doesn't overwrite header data.
    // Headers remain valid in buffer[0..headers_len], body uses the rest.
    std.debug.assert(reader.seek == parsed_len);
    const headers_len = reader.seek;
    reader.buffer = reader.buffer[headers_len..];
    reader.end -= headers_len;
    reader.seek = 0;

    // Feed empty buffer to advance state machine for bodyless requests
    parser.feed(&.{}) catch |err| switch (err) {
        error.Paused => {},
        else => |e| return e,
    };
}

/// A reader over `raw` with `body_read_reserve` bytes of slack past it, the
/// way a connection's read buffer has slack past the head it just parsed.
/// `Reader.fixed` alone leaves none, and a head with nothing behind it is
/// rejected -- the body reader would have nowhere to read into.
fn fixedMessageReader(gpa: std.mem.Allocator, raw: []const u8) !std.Io.Reader {
    const backing = try gpa.alloc(u8, raw.len + body_read_reserve);
    @memcpy(backing[0..raw.len], raw);
    var r: std.Io.Reader = .fixed(backing);
    r.end = raw.len;
    return r;
}

test "Request.setTimeout: forwards relative, absolute, and disabled deadlines" {
    const Probe = struct {
        calls: usize = 0,
        last: std.Io.Timeout = .none,

        fn set(context: *anyopaque, _: std.Io, timeout: std.Io.Timeout) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.last = timeout;
        }
    };

    var probe: Probe = .{};
    var req: Request = .{
        .arena = std.testing.allocator,
        .io = std.testing.io,
        .parser = undefined,
        .transport = undefined,
        ._timeout_context = &probe,
        ._set_timeout = Probe.set,
    };

    req.setTimeout(.{ .duration = .{ .raw = .fromSeconds(7), .clock = .awake } });
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(7), probe.last.duration.raw);

    const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .real).addDuration(.{
        .raw = .fromSeconds(11),
        .clock = .real,
    });
    req.setTimeout(.{ .deadline = deadline });
    try std.testing.expectEqual(deadline, probe.last.deadline);

    req.setTimeout(.none);
    try std.testing.expect(probe.last == .none);
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

test "Request: no std.Io.Reader sentinel escapes the body-reading API" {
    // `ReadFailed` says only that a read failed, which the caller knew when
    // it called. None of these may report it.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        ErrorSetOf(Request.body),
        ErrorSetOf(Request.jsonValue),
        ErrorSetOf(Request.formData),
        ErrorSetOf(Request.multiFormData),
        // The wrapper a streaming caller resolves through, not just the
        // functions that resolve for them.
        RequestBodyReader.Error,
    }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            try std.testing.expect(!std.mem.eql(u8, e.name, "ReadFailed"));
            // Not a sentinel, but not a cause either: the body layer calls a
            // stream that stopped early `IncompleteBody`, and `EndOfStream`
            // here would be read as the peer having hung up.
            try std.testing.expect(!std.mem.eql(u8, e.name, "EndOfStream"));
        }
    }
}

test "Request.body: basic POST" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
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

test "Request.body: a gzip request body is decoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "hello", gzip compressed.
    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectEqual(http.ContentEncoding.gzip, req.content_encoding);
    const body = try req.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "Request.body: a chunked gzip body is unwrapped by both layers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "Hello from test!" gzipped, then cut across three chunks -- so the
    // decoder is fed from a stream whose framing it cannot see.
    const chunked_gzip = "6\r\n\x1f\x8b\x08\x00\x00\x00\r\n" ++
        "e\r\n\x00\x00\x02\x03\xf3\x48\xcd\xc9\xc9\x57\x48\x2b\xca\xcf\r\n" ++
        "10\r\n\x55\x28\x49\x2d\x2e\x51\x04\x00\x7c\xe6\xd9\x99\x10\x00\x00\x00\r\n" ++
        "0\r\n\r\n";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n" ++ chunked_gzip;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqualStrings("Hello from test!", body.?);
}

test "Request.body: decoding off yields what the wire carried" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
        .config = .{ .decompress = false },
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const body = try req.body();
    try std.testing.expectEqualStrings(gzip_hello, body.?);
}

test "Request.body: a compressed body cut short is a bad body, not a departed peer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A valid gzip stream, truncated. The peer is still there and the HTTP
    // message is whole; it is the compressed stream inside that stops early.
    const cut_gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xcb\x48\xcd\xc9\xc9";
    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 15\r\n\r\n" ++ cut_gzip;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    // The decoder calls this `EndOfStream`, which is how a peer that hung up
    // is spelled -- `Transport.isPeerGone` would believe it and tear the
    // connection down rather than answering. The framing half already calls
    // the same condition `IncompleteBody`, and so must this one.
    try std.testing.expectError(error.IncompleteBody, req.body());
    try std.testing.expect(!Transport.isPeerGone(error.IncompleteBody));
}

test "Request.body: a coding we cannot undo is refused rather than guessed at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: br\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    // Handing the handler brotli bytes it would read as the body is worse
    // than saying we cannot.
    try std.testing.expectError(error.UnsupportedContentEncoding, req.body());
}

test "Request: a streaming read resolves through the reader it hands out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++
        ("not a gzip stream at all" ++ "12345678");
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    // A handler streaming the body never calls `body`, so the reader itself
    // has to answer -- including for a failure in the layer it added.
    var read_buf: [64]u8 = undefined;
    var r = try req.reader(&read_buf);
    var sink: std.Io.Writer = .fixed(&[_]u8{});
    try std.testing.expectError(error.ReadFailed, r.interface.stream(&sink, .limited(64)));
    try std.testing.expectEqual(error.BadGzipHeader, r.err.?);
}

test "Request.body: a body cut short reports the parse failure, not a failed read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The headers promise five bytes and the peer sends two, then stops.
    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 5\r\n\r\nhe";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    // Nothing is wrong with the connection, so it has no cause to offer.
    // The parser does: it is the layer that knows the body was short, and
    // the reader carries its answer up.
    try std.testing.expectError(error.ParseFailed, req.body());
}

test "Request.body: framing the parser rejects is reported as itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A chunk size that is not a number.
    const raw_request = "POST /test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectError(error.InvalidChunkSize, req.body());
}

test "Request.body: large body over 128 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body_content = "A" ** 256;
    const raw_request = "POST /test HTTP/1.1\r\nContent-Length: 256\r\n\r\n" ++ body_content;
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
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

test "Request.cookies: parse cookies from header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "GET /test HTTP/1.1\r\nCookie: session=abc123; user=john\r\n\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const cookies = req.cookies();
    try std.testing.expectEqualStrings("abc123", cookies.get("session").?);
    try std.testing.expectEqualStrings("john", cookies.get("user").?);
    try std.testing.expectEqual(null, cookies.get("missing"));
}

test "Request.formData: basic key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 15\r\n\r\nfoo=123&bar=abc";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
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
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
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
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
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

test "Request.multiFormData: basic key and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--boundary123\r\nContent-Length: 155\r\n\r\n----boundary123\r\nContent-Disposition: form-data; name=\"foo\"\r\n\r\n123\r\n----boundary123\r\nContent-Disposition: form-data; name=\"bar\"\r\n\r\nabc\r\n----boundary123--\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.multiFormData();
    try std.testing.expectEqualStrings("123", form_data.get("foo").?.value);
    try std.testing.expectEqualStrings("abc", form_data.get("bar").?.value);
}

test "Request.multiFormData: entry with filename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_request = "POST /test HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--boundary123\r\nContent-Length: 133\r\n\r\n----boundary123\r\nContent-Disposition: form-data; name=\"foo\"; filename=\"foo.txt\"\r\nContent-Type: text/plain\r\n\r\n123\r\n----boundary123--\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_request);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    const form_data = try req.multiFormData();
    try std.testing.expectEqualStrings("foo.txt", form_data.get("foo").?.filename.?);
}

test "Request.multiFormData: semicolon in attribute name (regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Content-Disposition attribute name containing ';' — the parser
    // searched for the value-terminating ';' from the field-name start
    // instead of from the value start, so value_end could land before
    // value_start and slice [value_start..value_end] panicked.
    const body = "----b\r\nContent-Disposition: form-data; name;x=v\r\n\r\nval\r\n----b--\r\n";
    var cl_buf: [16]u8 = undefined;
    const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});

    var req_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer req_buf.deinit(std.testing.allocator);
    try req_buf.appendSlice(std.testing.allocator, "POST /t HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--b\r\nContent-Length: ");
    try req_buf.appendSlice(std.testing.allocator, cl);
    try req_buf.appendSlice(std.testing.allocator, "\r\n\r\n");
    try req_buf.appendSlice(std.testing.allocator, body);

    var reader = try fixedMessageReader(arena.allocator(), req_buf.items);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    // Should error out cleanly, not panic.
    _ = req.multiFormData() catch {};
}

test "Request.multiFormData: trailing backslash in quoted attribute (regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Quoted name value ends with a backslash and no closing quote — the parser
    // currently looks at fields[pos+1] without bounds-checking, panicking on
    // safety-checked builds. Should return InvalidMultiPartEncoding instead.
    const body = "----b\r\nContent-Disposition: form-data; name=\"x\\\r\n\r\nval\r\n----b--\r\n";
    var cl_buf: [16]u8 = undefined;
    const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});

    var req_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer req_buf.deinit(std.testing.allocator);
    try req_buf.appendSlice(std.testing.allocator, "POST /t HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=--b\r\nContent-Length: ");
    try req_buf.appendSlice(std.testing.allocator, cl);
    try req_buf.appendSlice(std.testing.allocator, "\r\n\r\n");
    try req_buf.appendSlice(std.testing.allocator, body);

    var reader = try fixedMessageReader(arena.allocator(), req_buf.items);

    var req: Request = .{
        .arena = arena.allocator(),
        .transport = .{ .reader = &reader, .writer = undefined },
        .parser = undefined,
    };

    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req.parser = &parser;

    try parseHeaders(&reader, &parser);

    try std.testing.expectError(error.InvalidMultiPartEncoding, req.multiFormData());
}
