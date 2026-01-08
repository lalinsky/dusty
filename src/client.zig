const std = @import("std");
const zio = @import("zio");
const Uri = std.Uri;

const http = @import("http.zig");
const Method = http.Method;
const Status = http.Status;
const Headers = http.Headers;
const ContentType = http.ContentType;

const ResponseParser = @import("parser.zig").ResponseParser;
const ParsedResponse = @import("parser.zig").ParsedResponse;
const ResponseBodyReader = @import("parser.zig").ResponseBodyReader;
const KeepAliveParams = @import("parser.zig").KeepAliveParams;
const parseKeepAliveHeader = @import("parser.zig").parseKeepAliveHeader;

/// Configuration for the HTTP client.
pub const ClientConfig = struct {
    /// Maximum number of redirects to follow (0 = disabled).
    max_redirects: u8 = 10,
    /// Maximum response body size in bytes.
    max_response_size: usize = 10_485_760, // 10MB
    /// Maximum idle connections to keep in pool (0 = no pooling).
    max_idle_connections: u8 = 8,
};

/// Options for a single fetch request.
pub const FetchOptions = struct {
    method: Method = .get,
    headers: ?*const Headers = null,
    body: ?[]const u8 = null,
    /// Override default redirect limit for this request.
    max_redirects: ?u8 = null,
};

/// Parse a URL string into a std.Uri.
fn parseUrl(url: []const u8) !Uri {
    return Uri.parse(url) catch return error.InvalidUrl;
}

/// Get port from URI, defaulting based on scheme.
fn uriPort(uri: Uri) error{UnsupportedScheme}!u16 {
    if (uri.port) |p| return p;
    if (std.mem.eql(u8, uri.scheme, "http")) return 80;
    if (std.mem.eql(u8, uri.scheme, "https")) return 443;
    return error.UnsupportedScheme;
}

/// Get host string from URI.
fn uriHost(uri: Uri, buffer: []u8) ![]const u8 {
    return uri.getHost(buffer) catch return error.InvalidUrl;
}

/// Get path for HTTP request line.
fn uriPath(uri: Uri) []const u8 {
    const path = uri.path.percent_encoded;
    if (path.len == 0) return "/";
    return path;
}

/// Pool of idle connections for reuse.
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    idle: std.DoublyLinkedList,
    idle_len: usize,
    max_idle: u8,

    pub fn init(allocator: std.mem.Allocator, max_idle: u8) ConnectionPool {
        return .{
            .allocator = allocator,
            .idle = .{},
            .idle_len = 0,
            .max_idle = max_idle,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        // Close and free all idle connections
        while (self.idle.popFirst()) |node| {
            const conn: *Connection = @fieldParentPtr("pool_node", node);
            conn.deinit();
            self.allocator.destroy(conn);
        }
    }

    /// Try to acquire an existing connection for the given host:port.
    pub fn acquire(self: *ConnectionPool, rt: *zio.Runtime, remote_host: []const u8, remote_port: u16) ?*Connection {
        const now = rt.now();

        // Search from end (most recently used)
        var node = self.idle.last;
        while (node) |n| {
            const conn: *Connection = @fieldParentPtr("pool_node", n);
            node = n.prev;

            if (conn.matches(remote_host, remote_port)) {
                // Check if connection has expired due to idle timeout
                if (conn.idle_deadline) |deadline| {
                    if (now >= deadline) {
                        // Connection expired, remove and close it
                        self.idle.remove(n);
                        self.idle_len -= 1;
                        conn.deinit();
                        self.allocator.destroy(conn);
                        continue;
                    }
                }

                self.idle.remove(n);
                self.idle_len -= 1;
                return conn;
            }
        }
        return null;
    }

    /// Release a connection back to the pool, or close it if pool is full or connection is closing.
    pub fn release(self: *ConnectionPool, conn: *Connection) void {
        // Don't pool connections that are closing
        if (conn.closing or self.max_idle == 0) {
            conn.deinit();
            self.allocator.destroy(conn);
            return;
        }

        // If pool is full, close the oldest connection
        if (self.idle_len >= self.max_idle) {
            if (self.idle.popFirst()) |old_node| {
                const old: *Connection = @fieldParentPtr("pool_node", old_node);
                old.deinit();
                self.allocator.destroy(old);
                self.idle_len -= 1;
            }
        }

        // Reset and add to pool
        conn.reset();
        self.idle.append(&conn.pool_node);
        self.idle_len += 1;
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

    // Connection pool metadata
    pool_node: std.DoublyLinkedList.Node = .{},
    host_buffer: [Uri.host_name_max]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 0,
    closing: bool = false,

    // Keep-Alive tracking
    request_count: u16 = 0,
    keep_alive: KeepAliveParams = .{},
    idle_deadline: ?u64 = null, // milliseconds from rt.now()

    /// Initialize the connection in place (required because parser stores internal pointers).
    pub fn init(self: *Connection, allocator: std.mem.Allocator, rt: *zio.Runtime, stream: zio.net.Stream, remote_host: []const u8, remote_port: u16) void {
        self.allocator = allocator;
        self.stream = stream;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.rt = rt;
        self.closing = false;

        // Keep-Alive tracking
        self.request_count = 0;
        self.keep_alive = .{};
        self.idle_deadline = null;

        // Store host for connection pooling
        const len: u8 = @intCast(@min(remote_host.len, self.host_buffer.len));
        @memcpy(self.host_buffer[0..len], remote_host[0..len]);
        self.host_len = len;
        self.port = remote_port;

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
        self.closing = false;
    }

    pub fn host(self: *const Connection) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// Check if this connection matches the given host and port.
    pub fn matches(self: *const Connection, match_host: []const u8, match_port: u16) bool {
        return self.port == match_port and std.ascii.eqlIgnoreCase(self.host(), match_host);
    }
};

/// HTTP client response.
/// Call deinit() when done to release the connection.
pub const ClientResponse = struct {
    conn: *Connection,
    pool: *ConnectionPool,
    max_response_size: usize,

    // Cached body (read lazily)
    _body: ?[]const u8 = null,
    _body_read: bool = false,
    body_reader_buffer: [1024]u8 = undefined,

    /// Release the connection back to the pool (or close if not reusable).
    pub fn deinit(self: *ClientResponse) void {
        const conn = self.conn;

        // Increment request count
        conn.request_count +|= 1;

        // Check basic keep-alive from Connection header
        if (!conn.parser.shouldKeepAlive()) {
            conn.closing = true;
        } else {
            // Parse Keep-Alive header on first response
            if (conn.request_count == 1) {
                if (conn.parsed_response.headers.get("Keep-Alive")) |keep_alive| {
                    conn.keep_alive = parseKeepAliveHeader(keep_alive);
                }
            }

            // Update idle deadline after each request
            if (conn.keep_alive.timeout) |timeout| {
                conn.idle_deadline = conn.rt.now() + @as(u64, timeout) * 1000;
            }

            // Check if we've reached max requests
            if (conn.keep_alive.max) |max| {
                if (conn.request_count >= max) {
                    conn.closing = true;
                }
            }
        }

        self.pool.release(conn);
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
    pool: ConnectionPool,

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) Client {
        return .{
            .allocator = allocator,
            .config = config,
            .pool = ConnectionPool.init(allocator, config.max_idle_connections),
        };
    }

    pub fn deinit(self: *Client) void {
        self.pool.deinit();
    }

    /// Perform an HTTP request.
    pub fn fetch(
        self: *Client,
        rt: *zio.Runtime,
        url: []const u8,
        options: FetchOptions,
    ) !ClientResponse {
        const uri = try parseUrl(url);
        const max_redirects = options.max_redirects orelse self.config.max_redirects;
        return self.fetchInternal(rt, uri, options, max_redirects);
    }

    fn fetchInternal(
        self: *Client,
        rt: *zio.Runtime,
        uri: Uri,
        options: FetchOptions,
        redirects_remaining: u8,
    ) !ClientResponse {
        var host_buffer: [Uri.host_name_max]u8 = undefined;
        const host = try uriHost(uri, &host_buffer);
        const port = try uriPort(uri);

        // Try to get a connection from the pool
        const conn = self.pool.acquire(rt, host, port) orelse blk: {
            // No pooled connection, create a new one
            const addr = try zio.net.IpAddress.parseIp(host, port);
            const stream = try addr.connect(rt);
            errdefer stream.close(rt);

            const new_conn = try self.allocator.create(Connection);
            errdefer self.allocator.destroy(new_conn);
            new_conn.init(self.allocator, rt, stream, host, port);

            break :blk new_conn;
        };
        errdefer self.pool.release(conn);

        // Send request
        try writeRequest(&conn.writer.interface, options.method, uri, host, port, options.headers, options.body);

        // Parse response headers
        try parseResponseHeaders(&conn.reader.interface, &conn.parser);

        // Check for redirects
        const status_code = @intFromEnum(conn.parsed_response.status);
        if (status_code >= 300 and status_code < 400 and redirects_remaining > 0) {
            if (conn.parsed_response.headers.get("Location")) |location| {
                // Resolve redirect URL using RFC 3986
                var resolve_buf: [2048]u8 = undefined;
                if (location.len > resolve_buf.len) return error.InvalidUrl;
                @memcpy(resolve_buf[0..location.len], location);
                var aux_buf: []u8 = resolve_buf[0..];
                const redirect_uri = Uri.resolveInPlace(uri, location.len, &aux_buf) catch return error.InvalidUrl;

                // Release current connection back to pool
                conn.closing = !conn.parser.shouldKeepAlive();
                self.pool.release(conn);

                // For 303, always use GET and clear body
                var redirect_options = options;
                if (status_code == 303) {
                    redirect_options.method = .get;
                    redirect_options.body = null;
                }

                return self.fetchInternal(rt, redirect_uri, redirect_options, redirects_remaining - 1);
            }
        }

        // Build response (references connection and pool)
        return ClientResponse{
            .conn = conn,
            .pool = &self.pool,
            .max_response_size = self.config.max_response_size,
        };
    }
};

fn writeRequest(
    writer: *std.Io.Writer,
    method: Method,
    uri: Uri,
    host: []const u8,
    port: u16,
    headers_opt: ?*const Headers,
    body_content: ?[]const u8,
) !void {
    // Request line - path with query
    const path = uriPath(uri);
    if (uri.query) |query| {
        try writer.print("{s} {s}?{s} HTTP/1.1\r\n", .{ method.name(), path, query.percent_encoded });
    } else {
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method.name(), path });
    }

    // Host header
    if (port == 80) {
        try writer.print("Host: {s}\r\n", .{host});
    } else {
        try writer.print("Host: {s}:{d}\r\n", .{ host, port });
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

test "parseUrl: basic URL" {
    const uri = try parseUrl("http://example.com/path");
    var host_buf: [Uri.host_name_max]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    try std.testing.expectEqual(80, try uriPort(uri));
    try std.testing.expectEqualStrings("/path", uriPath(uri));
}

test "parseUrl: URL with port" {
    const uri = try parseUrl("http://example.com:8080/path");
    var host_buf: [Uri.host_name_max]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    try std.testing.expectEqual(8080, try uriPort(uri));
    try std.testing.expectEqualStrings("/path", uriPath(uri));
}

test "parseUrl: URL without path" {
    const uri = try parseUrl("http://example.com");
    var host_buf: [Uri.host_name_max]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    try std.testing.expectEqual(80, try uriPort(uri));
    try std.testing.expectEqualStrings("/", uriPath(uri));
}

test "parseUrl: URL without scheme is invalid" {
    try std.testing.expectError(error.InvalidUrl, parseUrl("example.com/path"));
}

test "parseUrl: HTTPS returns port 443" {
    const uri = try parseUrl("https://example.com/path");
    try std.testing.expectEqual(443, try uriPort(uri));
}

test "parseUrl: unknown scheme returns UnsupportedScheme" {
    const uri = try parseUrl("ftp://example.com/path");
    try std.testing.expectError(error.UnsupportedScheme, uriPort(uri));
}

test "parseUrl: URL with query string" {
    const uri = try parseUrl("http://example.com/path?foo=bar&baz=qux");
    var host_buf: [Uri.host_name_max]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    try std.testing.expectEqualStrings("/path", uriPath(uri));
    try std.testing.expectEqualStrings("foo=bar&baz=qux", uri.query.?.percent_encoded);
}

test "Uri.resolveInPlace: relative path" {
    const base = try parseUrl("http://example.com/foo/bar");

    // Test absolute path redirect
    {
        var buf: [256]u8 = undefined;
        const location = "/new/path";
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = try Uri.resolveInPlace(base, location.len, &aux);
        try std.testing.expectEqualStrings("http", resolved.scheme);
        try std.testing.expectEqualStrings("example.com", resolved.host.?.percent_encoded);
        try std.testing.expectEqualStrings("/new/path", resolved.path.percent_encoded);
    }

    // Test relative path redirect
    {
        var buf: [256]u8 = undefined;
        const location = "other";
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = try Uri.resolveInPlace(base, location.len, &aux);
        try std.testing.expectEqualStrings("http", resolved.scheme);
        try std.testing.expectEqualStrings("example.com", resolved.host.?.percent_encoded);
        try std.testing.expectEqualStrings("/foo/other", resolved.path.percent_encoded);
    }

    // Test absolute URL redirect
    {
        var buf: [256]u8 = undefined;
        const location = "http://other.com/different";
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = try Uri.resolveInPlace(base, location.len, &aux);
        try std.testing.expectEqualStrings("http", resolved.scheme);
        try std.testing.expectEqualStrings("other.com", resolved.host.?.percent_encoded);
        try std.testing.expectEqualStrings("/different", resolved.path.percent_encoded);
    }
}
