const std = @import("std");
const zio = @import("zio");

const http = @import("http.zig");
const Method = http.Method;
const Status = http.Status;
const Headers = http.Headers;
const ContentType = http.ContentType;

const ResponseParser = @import("parser.zig").ResponseParser;
const ParsedResponse = @import("parser.zig").ParsedResponse;
const ResponseBodyReader = @import("parser.zig").ResponseBodyReader;

/// Configuration for the HTTP client.
pub const ClientConfig = struct {
    /// Maximum number of redirects to follow (0 = disabled).
    max_redirects: u8 = 10,
    /// Maximum response body size in bytes.
    max_response_size: usize = 10_485_760, // 10MB
};

/// Options for a single fetch request.
pub const FetchOptions = struct {
    method: Method = .get,
    headers: ?*const Headers = null,
    body: ?[]const u8 = null,
    /// Override default redirect limit for this request.
    max_redirects: ?u8 = null,
};

/// Parsed URL components.
pub const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,

    pub fn parse(url: []const u8) !ParsedUrl {
        var remaining = url;

        // Strip "http://" prefix if present
        if (std.mem.startsWith(u8, remaining, "http://")) {
            remaining = remaining["http://".len..];
        } else if (std.mem.startsWith(u8, remaining, "https://")) {
            return error.TlsNotSupported;
        }

        // Find path start
        const path_start = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
        const host_port = remaining[0..path_start];
        const path = if (path_start < remaining.len) remaining[path_start..] else "/";

        // Validate host is not empty
        if (host_port.len == 0) {
            return error.InvalidUrl;
        }

        // Parse host:port
        if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
            const host = host_port[0..colon];
            const port_str = host_port[colon + 1 ..];
            if (host.len == 0 or port_str.len == 0) {
                return error.InvalidUrl;
            }
            const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
            return .{ .host = host, .port = port, .path = path };
        } else {
            return .{ .host = host_port, .port = 80, .path = path };
        }
    }
};

/// A client connection that owns all resources for a request/response cycle.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: zio.net.Stream,
    arena: std.heap.ArenaAllocator,
    parser: ResponseParser,
    parsed_response: ParsedResponse,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    reader: zio.net.Stream.Reader,
    writer: zio.net.Stream.Writer,
    rt: *zio.Runtime,

    /// Initialize the connection in place (required because parser stores internal pointers).
    pub fn init(self: *Connection, allocator: std.mem.Allocator, rt: *zio.Runtime, stream: zio.net.Stream) void {
        self.allocator = allocator;
        self.stream = stream;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.rt = rt;

        self.parsed_response = .{ .arena = self.arena.allocator() };
        self.parser.init(&self.parsed_response);
        self.reader = stream.reader(rt, &self.read_buffer);
        self.writer = stream.writer(rt, &self.write_buffer);
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.rt);
        self.arena.deinit();
    }

    pub fn reset(self: *Connection) void {
        // Reset for reuse (connection pooling)
        _ = self.arena.reset(.retain_capacity);
        self.parsed_response = .{ .arena = self.arena.allocator() };
        self.parser.reset();
        self.parser.init(&self.parsed_response);
    }
};

/// HTTP client response.
/// Call deinit() when done to release the connection.
pub const ClientResponse = struct {
    conn: *Connection,
    max_response_size: usize,

    // Cached body (read lazily)
    _body: ?[]const u8 = null,
    _body_read: bool = false,
    body_reader_buffer: [1024]u8 = undefined,

    /// Release the connection (closes it for now, pooling later).
    pub fn deinit(self: *ClientResponse) void {
        const allocator = self.conn.allocator;
        self.conn.deinit();
        allocator.destroy(self.conn);
    }

    /// Get response status.
    pub fn status(self: *const ClientResponse) Status {
        return self.conn.parsed_response.status;
    }

    /// Get response headers.
    pub fn headers(self: *const ClientResponse) *const Headers {
        return &self.conn.parsed_response.headers;
    }

    /// Get HTTP version.
    pub fn version(self: *const ClientResponse) struct { major: u8, minor: u8 } {
        return .{
            .major = self.conn.parsed_response.version_major,
            .minor = self.conn.parsed_response.version_minor,
        };
    }

    /// Get content type if present.
    pub fn contentType(self: *const ClientResponse) ?ContentType {
        return self.conn.parsed_response.content_type;
    }

    /// Read the entire response body into memory.
    /// Result is cached for subsequent calls.
    pub fn body(self: *ClientResponse) !?[]const u8 {
        if (self._body_read) {
            return self._body;
        }

        var r = self.reader();
        const result = r.interface.allocRemaining(self.conn.arena.allocator(), .limited(self.max_response_size)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
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

    /// Get a streaming body reader.
    pub fn reader(self: *ClientResponse) ResponseBodyReader {
        // If body has already been read, return a reader for the cached body
        if (self._body_read) {
            const cached_body = self._body orelse &.{};
            var r = ResponseBodyReader.init(&self.conn.parser, &self.conn.reader.interface, &self.body_reader_buffer);
            r.interface = std.Io.Reader.fixed(cached_body);
            return r;
        }

        // Return the streaming body reader
        return ResponseBodyReader.init(&self.conn.parser, &self.conn.reader.interface, &self.body_reader_buffer);
    }
};

/// HTTP client for making requests.
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) Client {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Client, rt: *zio.Runtime) void {
        _ = self;
        _ = rt;
        // TODO: Close pooled connections when pooling is implemented
    }

    /// Perform an HTTP request.
    pub fn fetch(
        self: *Client,
        rt: *zio.Runtime,
        url: []const u8,
        options: FetchOptions,
    ) !ClientResponse {
        const max_redirects = options.max_redirects orelse self.config.max_redirects;
        return self.fetchInternal(rt, url, options, max_redirects);
    }

    fn fetchInternal(
        self: *Client,
        rt: *zio.Runtime,
        url: []const u8,
        options: FetchOptions,
        redirects_remaining: u8,
    ) !ClientResponse {
        const parsed = try ParsedUrl.parse(url);

        // Connect to server
        const addr = try zio.net.IpAddress.parseIp(parsed.host, parsed.port);
        const stream = try addr.connect(rt);
        errdefer stream.close(rt);

        // Create connection (owns all resources)
        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);
        conn.init(self.allocator, rt, stream);
        errdefer conn.deinit();

        // Send request
        try writeRequest(&conn.writer.interface, options.method, parsed, options.headers, options.body);

        // Parse response headers
        try parseResponseHeaders(&conn.reader.interface, &conn.parser);

        // Check for redirects
        const status_code = @intFromEnum(conn.parsed_response.status);
        if (status_code >= 300 and status_code < 400 and redirects_remaining > 0) {
            if (conn.parsed_response.headers.get("Location")) |location| {
                // Resolve redirect URL
                const redirect_url = try resolveRedirectUrl(url, location);

                // Close current connection
                conn.deinit();
                self.allocator.destroy(conn);

                // For 303, always use GET and clear body
                var redirect_options = options;
                if (status_code == 303) {
                    redirect_options.method = .get;
                    redirect_options.body = null;
                }

                return self.fetchInternal(rt, redirect_url, redirect_options, redirects_remaining - 1);
            }
        }

        // Build response (references connection)
        return ClientResponse{
            .conn = conn,
            .max_response_size = self.config.max_response_size,
        };
    }
};

fn writeRequest(
    writer: *std.Io.Writer,
    method: Method,
    parsed: ParsedUrl,
    headers_opt: ?*const Headers,
    body_content: ?[]const u8,
) !void {
    // Request line
    try writer.print("{s} {s} HTTP/1.1\r\n", .{ method.name(), parsed.path });

    // Host header
    if (parsed.port == 80) {
        try writer.print("Host: {s}\r\n", .{parsed.host});
    } else {
        try writer.print("Host: {s}:{d}\r\n", .{ parsed.host, parsed.port });
    }

    // Content-Length for body
    if (body_content) |b| {
        try writer.print("Content-Length: {d}\r\n", .{b.len});
    }

    // User-provided headers
    if (headers_opt) |h| {
        var it = h.iterator();
        while (it.next()) |entry| {
            // Skip headers we already set
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Host")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Content-Length")) continue;

            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    // End of headers
    try writer.writeAll("\r\n");

    // Body
    if (body_content) |b| {
        try writer.writeAll(b);
    }

    try writer.flush();
}

fn resolveRedirectUrl(base_url: []const u8, location: []const u8) ![]const u8 {
    // If location is absolute, use it directly
    if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
        return location;
    }

    // For relative URLs starting with /, construct absolute URL
    // For now, just return location and hope it works
    // TODO: Proper URL resolution
    _ = base_url;
    return location;
}

/// Parse HTTP response headers from a reader.
fn parseResponseHeaders(reader: *std.Io.Reader, parser: *ResponseParser) !void {
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
                return error.IncompleteResponse;
            },
            else => return err,
        };
    }
    reader.toss(parsed_len);
    parser.resumeParsing();

    // Feed empty buffer to advance state machine for bodyless responses
    parser.feed(&.{}) catch |err| switch (err) {
        error.Paused => {},
        else => return err,
    };
}

// Tests

test "ParsedUrl: basic URL" {
    const url = try ParsedUrl.parse("http://example.com/path");
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(80, url.port);
    try std.testing.expectEqualStrings("/path", url.path);
}

test "ParsedUrl: URL with port" {
    const url = try ParsedUrl.parse("http://example.com:8080/path");
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(8080, url.port);
    try std.testing.expectEqualStrings("/path", url.path);
}

test "ParsedUrl: URL without path" {
    const url = try ParsedUrl.parse("http://example.com");
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(80, url.port);
    try std.testing.expectEqualStrings("/", url.path);
}

test "ParsedUrl: URL without scheme" {
    const url = try ParsedUrl.parse("example.com/path");
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(80, url.port);
    try std.testing.expectEqualStrings("/path", url.path);
}

test "ParsedUrl: HTTPS not supported" {
    const result = ParsedUrl.parse("https://example.com/path");
    try std.testing.expectError(error.TlsNotSupported, result);
}

test "ParsedUrl: empty URL" {
    const result = ParsedUrl.parse("");
    try std.testing.expectError(error.InvalidUrl, result);
}
