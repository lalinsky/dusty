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
    /// Buffer size (bytes) for reading response headers.
    buffer_size: usize = 4096,
};

/// Options for a single fetch request.
pub const FetchOptions = struct {
    method: Method = .get,
    headers: ?*const Headers = null,
    body: ?[]const u8 = null,
    /// Override default redirect limit for this request.
    max_redirects: ?u8 = null,
    /// Decompress response body automatically (sends Accept-Encoding header).
    decompress: bool = true,
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
    pub fn acquire(self: *ConnectionPool, io: *zio.Runtime, remote_host: []const u8, remote_port: u16) ?*Connection {
        const now = io.now();

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
    write_buffer: [4096]u8,
    reader: zio.net.Stream.Reader,
    writer: zio.net.Stream.Writer,
    io: *zio.Runtime,
    buffer_size: usize,
    pool: *ConnectionPool,

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
    pub fn init(self: *Connection, allocator: std.mem.Allocator, io: *zio.Runtime, pool: *ConnectionPool, stream: zio.net.Stream, remote_host: []const u8, remote_port: u16, buffer_size: usize) !void {
        self.allocator = allocator;
        self.stream = stream;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.io = io;
        self.pool = pool;
        self.closing = false;
        self.buffer_size = buffer_size;

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
        self.reader = stream.reader(io, &.{});
        self.writer = stream.writer(io, &self.write_buffer);

        // Allocate initial read buffer from arena
        try self.allocReadBuffer();
    }

    /// Allocate read buffer from arena for parsing response headers.
    fn allocReadBuffer(self: *Connection) !void {
        const read_buffer = try self.arena.allocator().alloc(u8, self.buffer_size + 1024);
        self.reader.interface.buffer = read_buffer;
        self.reader.interface.seek = 0;
        self.reader.interface.end = 0;
    }

    pub fn deinit(self: *Connection) void {
        self.stream.close(self.io);
        self.arena.deinit();
    }

    pub fn reset(self: *Connection) void {
        // Reset for reuse (connection pooling)
        _ = self.arena.reset(.retain_capacity);
        self.parsed_response = .{ .arena = self.arena.allocator() };
        self.parser.reset();
        self.parser.init(&self.parsed_response);
        self.closing = false;

        // Allocate fresh read buffer after arena reset (can't fail - capacity retained)
        self.allocReadBuffer() catch unreachable;
    }

    pub fn host(self: *const Connection) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    /// Check if this connection matches the given host and port.
    pub fn matches(self: *const Connection, match_host: []const u8, match_port: u16) bool {
        return self.port == match_port and std.ascii.eqlIgnoreCase(self.host(), match_host);
    }

    /// Release this connection back to its pool, handling keep-alive logic.
    pub fn release(self: *Connection) void {
        // Increment request count
        self.request_count +|= 1;

        // Check basic keep-alive from Connection header
        if (!self.parser.shouldKeepAlive()) {
            self.closing = true;
        } else {
            // Parse Keep-Alive header on first response
            if (self.request_count == 1) {
                if (self.parsed_response.headers.get("Keep-Alive")) |keep_alive| {
                    self.keep_alive = parseKeepAliveHeader(keep_alive);
                }
            }

            // Update idle deadline after each request
            if (self.keep_alive.timeout) |timeout| {
                self.idle_deadline = self.io.now() + @as(u64, timeout) * 1000;
            }

            // Check if we've reached max requests
            if (self.keep_alive.max) |max| {
                if (self.request_count >= max) {
                    self.closing = true;
                }
            }
        }

        self.pool.release(self);
    }
};

/// HTTP client response.
/// Call deinit() when done to release the connection.
pub const ClientResponse = struct {
    // Direct pointers for reading (testable without full connection)
    arena: std.mem.Allocator,
    parser: *ResponseParser,
    conn: *std.Io.Reader,
    parsed: *ParsedResponse,
    max_response_size: usize,
    decompress: bool = true,

    // Cached body (read lazily)
    _body: ?[]const u8 = null,
    _body_read: bool = false,

    // Body reader state (stored here for stable address needed by decompressor)
    _body_reader: ResponseBodyReader = undefined,
    _body_reader_buffer: [1024]u8 = undefined,
    _body_reader_init: bool = false,

    // Decompression state
    _decompressor: std.compress.flate.Decompress = undefined,
    _decompressor_buffer: [std.compress.flate.max_window_len]u8 = undefined,
    _decompressor_init: bool = false,

    // Connection reference for cleanup (optional for testing)
    owner: ?*Connection = null,

    /// Release the connection back to the pool (or close if not reusable).
    pub fn deinit(self: *ClientResponse) void {
        if (self.owner) |conn| {
            conn.release();
        }
    }

    /// Get response status.
    pub fn status(self: *const ClientResponse) Status {
        return self.parsed.status;
    }

    /// Get response headers.
    pub fn headers(self: *const ClientResponse) *const Headers {
        return &self.parsed.headers;
    }

    /// Get HTTP version.
    pub fn version(self: *const ClientResponse) struct { major: u8, minor: u8 } {
        return .{
            .major = self.parsed.version_major,
            .minor = self.parsed.version_minor,
        };
    }

    /// Get content type if present.
    pub fn contentType(self: *const ClientResponse) ?ContentType {
        return self.parsed.content_type;
    }

    /// Read the entire response body into memory.
    /// Result is cached for subsequent calls.
    pub fn body(self: *ClientResponse) !?[]const u8 {
        if (self._body_read) {
            return self._body;
        }

        const r = self.reader();
        const result = r.allocRemaining(self.arena, .limited(self.max_response_size)) catch |err| switch (err) {
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

    /// Get a streaming body reader. Returns decompressed data if server sent
    /// compressed response and decompress option was enabled.
    pub fn reader(self: *ClientResponse) *std.Io.Reader {
        // If body has already been read, return a reader for the cached body
        if (self._body_read) {
            const cached_body = self._body orelse &.{};
            self._body_reader = ResponseBodyReader.init(self.parser, self.conn, &self._body_reader_buffer);
            self._body_reader.interface = std.Io.Reader.fixed(cached_body);
            return &self._body_reader.interface;
        }

        // Initialize body reader if not already done
        if (!self._body_reader_init) {
            self._body_reader = ResponseBodyReader.init(self.parser, self.conn, &self._body_reader_buffer);
            self._body_reader_init = true;
        }

        // If decompression enabled and response is compressed, wrap with decompressor
        if (self.decompress and self.parsed.content_encoding != .identity and !self._decompressor_init) {
            self._decompressor = std.compress.flate.Decompress.init(
                &self._body_reader.interface,
                if (self.parsed.content_encoding == .gzip) .gzip else .zlib,
                &self._decompressor_buffer,
            );
            self._decompressor_init = true;
        }

        if (self._decompressor_init) {
            return &self._decompressor.reader;
        }

        return &self._body_reader.interface;
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
        io: *zio.Runtime,
        url: []const u8,
        options: FetchOptions,
    ) !ClientResponse {
        const uri = try parseUrl(url);
        const max_redirects = options.max_redirects orelse self.config.max_redirects;
        return self.fetchInternal(io, uri, options, max_redirects);
    }

    fn fetchInternal(
        self: *Client,
        io: *zio.Runtime,
        uri: Uri,
        options: FetchOptions,
        redirects_remaining: u8,
    ) !ClientResponse {
        var host_buffer: [Uri.host_name_max]u8 = undefined;
        const host = try uriHost(uri, &host_buffer);
        const port = try uriPort(uri);

        // Try to get a connection from the pool
        const conn = self.pool.acquire(io, host, port) orelse blk: {
            // No pooled connection, create a new one
            const stream = try zio.net.tcpConnectToHost(io, host, port);
            errdefer stream.close(io);

            const new_conn = try self.allocator.create(Connection);
            errdefer self.allocator.destroy(new_conn);
            try new_conn.init(self.allocator, io, &self.pool, stream, host, port, self.config.buffer_size);

            break :blk new_conn;
        };
        errdefer self.pool.release(conn);

        // Send request
        try writeRequest(&conn.writer.interface, .{
            .method = options.method,
            .uri = uri,
            .host = host,
            .port = port,
            .headers = options.headers,
            .body = options.body,
            .decompress = options.decompress,
        });

        // Parse response headers
        try parseResponseHeaders(&conn.reader.interface, &conn.parser);

        // Check for unsupported content encoding
        if (options.decompress and conn.parsed_response.content_encoding == .unknown) {
            return error.UnsupportedContentEncoding;
        }

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

                return self.fetchInternal(io, redirect_uri, redirect_options, redirects_remaining - 1);
            }
        }

        // Build response with direct pointers for reading
        return ClientResponse{
            .arena = conn.arena.allocator(),
            .parser = &conn.parser,
            .conn = &conn.reader.interface,
            .parsed = &conn.parsed_response,
            .max_response_size = self.config.max_response_size,
            .decompress = options.decompress,
            .owner = conn,
        };
    }
};

const WriteRequestOptions = struct {
    method: Method,
    uri: Uri,
    host: []const u8,
    port: u16,
    headers: ?*const Headers = null,
    body: ?[]const u8 = null,
    decompress: bool = true,
};

fn writeRequest(writer: *std.Io.Writer, opts: WriteRequestOptions) !void {
    // Request line - path with query
    const path = uriPath(opts.uri);
    if (opts.uri.query) |query| {
        try writer.print("{s} {s}?{s} HTTP/1.1\r\n", .{ opts.method.name(), path, query.percent_encoded });
    } else {
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ opts.method.name(), path });
    }

    // Host header
    if (opts.port == 80) {
        try writer.print("Host: {s}\r\n", .{opts.host});
    } else {
        try writer.print("Host: {s}:{d}\r\n", .{ opts.host, opts.port });
    }

    // Content-Length for body
    if (opts.body) |b| {
        try writer.print("Content-Length: {d}\r\n", .{b.len});
    }

    // User-provided headers
    var has_accept_encoding = false;
    if (opts.headers) |h| {
        var it = h.iterator();
        while (it.next()) |entry| {
            // Skip headers we already set
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Host")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Content-Length")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Accept-Encoding")) has_accept_encoding = true;

            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    // Add default Accept-Encoding if decompress enabled and user didn't provide one
    if (opts.decompress and !has_accept_encoding) {
        try writer.writeAll("Accept-Encoding: gzip, deflate\r\n");
    }

    // End of headers
    try writer.writeAll("\r\n");

    // Body
    if (opts.body) |b| {
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

    // Shorten buffer so body reading doesn't overwrite header data.
    // Headers remain valid in buffer[0..headers_len], body uses the rest.
    std.debug.assert(reader.seek == parsed_len);
    const headers_len = reader.seek;
    reader.buffer = reader.buffer[headers_len..];
    reader.end -= headers_len;
    reader.seek = 0;

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

test "ClientResponse.body: basic response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "ClientResponse.body: large body over 128 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body_content = "A" ** 256;
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 256\r\n\r\n" ++ body_content;
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqual(256, body.?.len);
    try std.testing.expectEqualStrings(body_content, body.?);
}

test "ClientResponse.body: no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqual(null, body);
    try std.testing.expectEqual(.no_content, response.status());
}

test "ClientResponse.reader: streaming read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world";
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body_reader = response.reader();

    // Read in chunks
    var buf: [5]u8 = undefined;
    var n = try body_reader.readSliceShort(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    n = try body_reader.readSliceShort(&buf);
    try std.testing.expectEqualStrings(" worl", buf[0..n]);

    n = try body_reader.readSliceShort(&buf);
    try std.testing.expectEqualStrings("d", buf[0..n]);
}

test "ClientResponse.reader: after body() returns cached data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    // First read body fully
    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);

    // Now reader should return cached body
    const body_reader = response.reader();
    const cached = try body_reader.allocRemaining(arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("hello", cached);
}

test "ClientResponse.body: gzip decompression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "hello" gzip compressed
    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
        .decompress = true,
    };

    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "ClientResponse.body: gzip decompression disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "hello" gzip compressed
    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = std.Io.Reader.fixed(raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    parser.init(&parsed);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .conn = &reader,
        .parsed = &parsed,
        .max_response_size = 1024,
        .decompress = false,
    };

    // With decompress disabled, we should get the raw gzip bytes
    const body = try response.body();
    try std.testing.expectEqual(25, body.?.len);
    try std.testing.expectEqualStrings(gzip_hello, body.?);
}
