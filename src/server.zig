const std = @import("std");
const zio = @import("zio");
const tls = @import("tls");
const build_options = @import("build_options");

const Router = @import("router.zig").Router;
const Action = @import("router.zig").Action;
const RequestParser = @import("parser.zig").RequestParser;
const RequestBodyReader = @import("parser.zig").RequestBodyReader;
const Request = @import("request.zig").Request;
const parseHeaders = @import("request.zig").parseHeaders;
const Response = @import("response.zig").Response;
const ServerConfig = @import("config.zig").ServerConfig;
const Executor = @import("middleware.zig").Executor;
const Middleware = @import("middleware.zig").Middleware;
const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;

const log = std.log.scoped(.dusty);

/// Owns the reader/writer (and, for TLS, the whole TLS + underlying TCP
/// layer), plus the arena backing their buffers, for one accepted
/// connection. Initialized in place: `tls_conn` stores pointers into
/// `tcp_reader`/`tcp_writer`, and `tls_reader`/`tls_writer` store a pointer
/// back into `tls_conn`, so a `Connection` must never be moved after
/// `initPlain`/`initTls` runs.
pub const Connection = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    arena: std.heap.ArenaAllocator = undefined,

    tcp_reader: std.Io.net.Stream.Reader = undefined,
    tcp_writer: std.Io.net.Stream.Writer = undefined,
    write_buffer: [4096]u8 = undefined,

    // TLS layer: tcp_reader/tcp_writer above carry ciphertext; tls_conn wraps
    // them, and tls_reader/tls_writer expose the cleartext Reader/Writer used
    // for HTTP I/O.
    tls_conn: ?tls.Connection = null,
    tls_rng: std.Random.IoSource = undefined,
    tls_cleartext_write_buffer: [4096]u8 = undefined,
    tls_reader: tls.Connection.Reader = undefined,
    tls_writer: tls.Connection.Writer = undefined,

    // Active reader/writer, whichever path is in use.
    reader: *std.Io.Reader = undefined,
    writer: *std.Io.Writer = undefined,

    pub fn initPlain(self: *Connection, allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream) void {
        self.* = .{ .io = io, .stream = stream };
        self.arena = .init(allocator);
        self.tcp_reader = stream.reader(io, &.{});
        self.tcp_writer = stream.writer(io, &self.write_buffer);
        self.reader = &self.tcp_reader.interface;
        self.writer = &self.tcp_writer.interface;
    }

    pub fn initTls(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        request_buffer_size: usize,
        auth: *tls.config.CertKeyPair,
    ) !void {
        self.* = .{ .io = io, .stream = stream };
        self.arena = .init(allocator);

        // Aim for a single backing allocation per connection: prime the
        // arena with room for the two TLS record buffers plus a working
        // budget, then recycle it (reset keeps the memory). The TLS buffers
        // and the per-request arena are then carved from that one
        // allocation; only unusually large requests grow it.
        const conn_reserve = tls.input_buffer_len + tls.output_buffer_len + 2 * (request_buffer_size + 1024);
        _ = try self.arena.allocator().alloc(u8, conn_reserve);
        _ = self.arena.reset(.retain_capacity);

        // The TLS record buffers live for the whole connection (the
        // tls.Connection points into them) and must survive the per-request
        // arena resets, so they come from the connection arena.
        const tcp_read_buffer = try self.arena.allocator().alloc(u8, tls.input_buffer_len);
        const tcp_write_buffer = try self.arena.allocator().alloc(u8, tls.output_buffer_len);

        self.tcp_reader = stream.reader(io, tcp_read_buffer);
        self.tcp_writer = stream.writer(io, tcp_write_buffer);
        self.tls_rng = .{ .io = io };
        self.tls_conn = try tls.server(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
            .auth = auth,
            .now = std.Io.Clock.real.now(io),
            .rng = self.tls_rng.interface(),
        });
        self.tls_reader = self.tls_conn.?.reader(&.{});
        self.tls_writer = self.tls_conn.?.writer(&self.tls_cleartext_write_buffer);
        self.reader = &self.tls_reader.interface;
        self.writer = &self.tls_writer.interface;
    }

    /// For tests: wraps a bare writer with no real TLS/TCP layer behind it.
    /// `tcp_writer.err` is left settable so a test can simulate the real
    /// error a write failure should surface.
    pub fn initWriterForTesting(self: *Connection, w: *std.Io.Writer) void {
        self.* = .{ .io = undefined, .stream = undefined, .reader = undefined, .writer = w };
        self.tcp_reader.err = null;
        self.tcp_writer.err = null;
    }

    pub fn deinit(self: *Connection) void {
        self.arena.deinit();
    }

    // tls.zig records `TransportReadFailed`/`TransportWriteFailed` when the
    // layer below it failed, because all it saw was the ciphertext
    // reader/writer's generic error; the real cause is on the TCP layer.
    // So those two mean "keep descending". A TLS-level failure (bad record
    // mac, bad version, ...) is recorded as itself and stops the search.

    fn checkReadError(self: *Connection) !void {
        if (build_options.use_tls) {
            if (self.tls_conn != null) {
                if (self.tls_reader.err) |e| if (e != error.TransportReadFailed) return e;
            }
        }
        if (self.tcp_reader.err) |e| return e;
    }

    /// The real error behind a generic `error.ReadFailed`, if any was recorded.
    pub fn getReadError(self: *Connection) ?@typeInfo(@TypeOf(checkReadError(self))).error_union.error_set {
        if (checkReadError(self)) |_| return null else |e| return e;
    }

    fn checkWriteError(self: *Connection) !void {
        if (build_options.use_tls) {
            if (self.tls_conn != null) {
                if (self.tls_writer.err) |e| if (e != error.TransportWriteFailed) return e;
            }
        }
        if (self.tcp_writer.err) |e| return e;
    }

    /// The error type `getWriteError` yields.
    pub const WriteError = @typeInfo(@TypeOf(checkWriteError(undefined))).error_union.error_set;

    /// The real error behind a generic `error.WriteFailed`, if any was
    /// recorded.
    pub fn getWriteError(self: *Connection) ?@typeInfo(@TypeOf(checkWriteError(self))).error_union.error_set {
        if (checkWriteError(self)) |_| return null else |e| return e;
    }

    /// True when `err` means the peer is gone rather than something being
    /// wrong. Teardown is the same either way; this only decides whether the
    /// connection is worth a log line and whether shutdown() is worth a
    /// syscall.
    pub fn isPeerGone(err: anyerror) bool {
        return switch (err) {
            error.EndOfStream,
            // Peer closed the transport between TLS records without
            // close_notify. Rude, but routine from clients that just close
            // the socket. `TlsTruncated`, where a record was cut in half, is
            // deliberately not here.
            error.TlsUnexpectedEof,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            => true,
            else => false,
        };
    }
};

pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    unix: std.Io.net.UnixAddress,

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .ip => |ip| try ip.format(w),
            .unix => |unix| try w.writeAll(unix.path),
        }
    }
};

pub fn Server(comptime Ctx: type) type {
    const MiddlewareItem = struct {
        middleware: Middleware(Ctx),
        node: std.SinglyLinkedList.Node = .{},
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        router: Router(Ctx),
        ctx: if (Ctx == void) void else *Ctx,
        config: ServerConfig,
        shutting_down: std.atomic.Value(bool),
        active_connections: std.atomic.Value(u32),
        address: Address,
        ready: std.Io.Event,
        _middleware_registry: std.SinglyLinkedList,
        /// Server certificate/key, loaded once in listen() when config.tls is set.
        tls_auth: ?tls.config.CertKeyPair = null,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ServerConfig, ctx: if (Ctx == void) void else *Ctx) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .shutting_down = std.atomic.Value(bool).init(false),
                .active_connections = std.atomic.Value(u32).init(0),
                .address = undefined,
                .ready = .unset,
                ._middleware_registry = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            // Call deinit on all registered middlewares
            var it = self._middleware_registry.first;
            while (it) |node| {
                it = node.next;
                const item: *MiddlewareItem = @fieldParentPtr("node", node);
                item.middleware.deinit();
            }
            self.router.deinit();
        }

        /// Creates a middleware instance managed by the server.
        /// The middleware is allocated on the router's arena and will be freed when the server is deinit'd.
        /// Supports middlewares with init(Config) or init(Config, MiddlewareConfig) signatures.
        pub fn middleware(self: *Self, comptime M: type, config: M.Config) !Middleware(Ctx) {
            const arena = self.router.arena.allocator();
            const m = try arena.create(M);
            m.* = switch (@typeInfo(@TypeOf(M.init)).@"fn".params.len) {
                1 => try M.init(config),
                2 => try M.init(config, MiddlewareConfig{
                    .arena = arena,
                    .allocator = self.allocator,
                }),
                else => @compileError(@typeName(M) ++ ".init must accept 1 or 2 parameters"),
            };

            const mw = Middleware(Ctx).init(m);

            // Register for cleanup on deinit
            const item = try arena.create(MiddlewareItem);
            item.* = .{ .middleware = mw };
            self._middleware_registry.prepend(&item.node);

            return mw;
        }

        pub fn listen(self: *Self, addr: Address) !void {
            // Load the server certificate/key once, shared across all connections.
            if (build_options.use_tls) {
                if (self.config.tls) |tls_cfg| {
                    const dir = tls_cfg.dir orelse std.Io.Dir.cwd();
                    self.tls_auth = tls.config.CertKeyPair.fromFilePath(
                        self.allocator,
                        self.io,
                        dir,
                        tls_cfg.cert_path,
                        tls_cfg.key_path,
                    ) catch |err| {
                        log.err("Failed to load TLS certificate/key: {}", .{err});
                        return err;
                    };
                }
            } else if (self.config.tls != null) {
                log.err("config.tls is set but the library was built with use_tls=false", .{});
                return error.TlsNotConfigured;
            }
            defer if (build_options.use_tls) {
                if (self.tls_auth) |*auth| {
                    auth.deinit(self.allocator);
                    self.tls_auth = null;
                }
            };

            var server = switch (addr) {
                .ip => |ip| try ip.listen(self.io, self.config.listen),
                .unix => |unix| try unix.listen(self.io, .{}),
            };
            defer server.deinit(self.io);

            self.address = switch (addr) {
                .ip => .{ .ip = server.socket.address },
                .unix => |unix| .{ .unix = unix },
            };
            self.ready.set(self.io);

            log.info("Listening on {f}", .{self.address});

            var group: std.Io.Group = .init;
            defer {
                self.shutting_down.store(true, .release);
                group.cancel(self.io);
            }

            while (true) {
                const stream = server.accept(self.io) catch |err| {
                    if (err == error.Canceled) {
                        log.info("Graceful shutdown requested", .{});
                        self.shutting_down.store(true, .release);
                        while (true) { // TODO: add graceful shutdown timeout
                            const remaining = self.active_connections.load(.acquire);
                            if (remaining == 0) break;
                            log.info("Waiting for {} remaining connections to close", .{remaining});
                            // Returns immediately if the count already changed, otherwise
                            // blocks until a close wakes it or the timeout expires.
                            try self.io.futexWaitTimeout(u32, &self.active_connections.raw, remaining, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(100), .clock = .awake } });
                            // No connection closed within the timeout. Let the deferred
                            // group.cancel tear down the remaining handlers.
                            if (self.active_connections.load(.acquire) == remaining) return error.Timeout;
                        }
                        return err;
                    }
                    return err;
                };

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                group.concurrent(self.io, handleConnectionWrapper, .{ self, stream }) catch |err| {
                    log.err("Failed to spawn connection handler: {}", .{err});
                    _ = self.active_connections.fetchSub(1, .acq_rel);
                    stream.close(self.io);
                    continue;
                };
            }
        }

        fn handleConnectionWrapper(self: *Self, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            handleConnection(self, stream) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                // A peer disappearing mid-request is ordinary and would drown
                // out the failures worth looking at.
                if (Connection.isPeerGone(err)) {
                    log.debug("Connection closed by peer: {}", .{err});
                } else {
                    log.err("Connection error: {}", .{err});
                }
            };
        }

        pub fn handleConnection(self: *Self, stream: std.Io.net.Stream) !void {
            defer {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                self.io.futexWake(u32, &self.active_connections.raw, 1);
            }

            defer stream.close(self.io);

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(self.io, .both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var connection: Connection = undefined;
            defer connection.deinit();

            // When TLS is configured, upgrade the accepted stream and run the
            // request loop over the cleartext reader/writer. Otherwise run it
            // directly over the raw stream.
            if (build_options.use_tls) {
                if (self.tls_auth) |*auth| {
                    // The handshake is the one part of a connection's life
                    // the request loop's timeout cannot cover, since that
                    // loop does not exist yet. A peer that opens a socket
                    // and then stalls mid-handshake would otherwise hold a
                    // task and the connection's whole buffer reservation
                    // for as long as it likes -- cheaper for it than a
                    // slow request, which is bounded.
                    {
                        var handshake: zio.AutoCancel = .init;
                        defer handshake.clear();
                        if (self.config.timeout.request) |duration| {
                            handshake.set(.fromMilliseconds(@intCast(duration.toMilliseconds())));
                        }

                        connection.initTls(self.allocator, self.io, stream, self.config.request.buffer_size, auth) catch |err| {
                            log.err("TLS handshake failed: {}", .{err});
                            return;
                        };
                    }

                    // Per-request arena nested on the connection arena: resetting it
                    // between keepalive requests reuses the connection's memory
                    // without touching the TLS buffers carved above.
                    var request_arena = std.heap.ArenaAllocator.init(connection.arena.allocator());
                    return self.handleRequests(&connection, &request_arena, &needs_shutdown);
                }
            }

            connection.initPlain(self.allocator, self.io, stream);
            return self.handleRequests(&connection, &connection.arena, &needs_shutdown);
        }

        /// Runs the HTTP request/keepalive loop over a connection.
        fn handleRequests(
            self: *Self,
            connection: *Connection,
            arena: *std.heap.ArenaAllocator,
            needs_shutdown: *bool,
        ) !void {
            var request: Request = .{
                .arena = arena.allocator(),
                .io = self.io,
                .conn = connection.reader,
                .parser = undefined,
                .config = self.config.request,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            var timeout: zio.AutoCancel = .init;
            defer timeout.clear();

            // Allocate initial buffer from arena
            connection.reader.buffer = request.arena.alloc(u8, self.config.request.buffer_size + 1024) catch |err| {
                log.err("Failed to allocate read buffer: {}", .{err});
                return err;
            };

            while (true) {
                request_count += 1;

                if (self.config.timeout.request) |duration| {
                    timeout.set(.fromMilliseconds(@intCast(duration.toMilliseconds())));
                }

                parseHeaders(connection.reader, &parser) catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown.* = false;
                        return;
                    },
                    error.ReadFailed => return connection.getReadError() orelse error.ReadFailed,
                    else => |e| return e,
                };

                log.debug("Received: {f} {s}", .{ request.method, request.url });

                var response = try Response.init(arena.allocator(), connection, self.config.request.max_header_count);
                response.head = request.method == .head;
                request.response = &response;

                // Handle Expect header (100-continue)
                if (request.headers.get("Expect")) |expect| {
                    if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                        request.expects_continue = true;
                    } else {
                        // Unknown Expect value - return 417
                        response.status = .expectation_failed;
                        response.keepalive = false;
                        try response.write();
                        return;
                    }
                }

                // Check if the connection allows keepalive
                if (!parser.shouldKeepAlive()) {
                    response.keepalive = false;
                }

                // Check if we've reached the request count limit
                if (self.config.timeout.request_count) |max_count| {
                    if (request_count >= max_count) {
                        response.keepalive = false;
                    }
                }

                const found = try self.router.findHandler(&request);
                var executor = Executor(Ctx){
                    .req = &request,
                    .res = &response,
                    .ctx = self.ctx,
                    .action = if (found) |r| r.action else null,
                    .middlewares = if (found) |r| r.middlewares else self.router.middlewares,
                };
                executor.run() catch |err| switch (err) {
                    error.ReadFailed => return connection.getReadError() orelse error.ReadFailed,
                    error.WriteFailed => return connection.getWriteError() orelse error.WriteFailed,
                    else => |e| return e,
                };

                if (!parser.isBodyComplete()) {
                    const max = self.config.request.max_body_size;
                    const drainable = blk: {
                        const cl = request.headers.get("Content-Length") orelse break :blk false;
                        const n = std.fmt.parseInt(usize, cl, 10) catch break :blk false;
                        break :blk n <= max;
                    };
                    if (drainable) {
                        var scratch: [4096]u8 = undefined;
                        var body_reader = RequestBodyReader.init(&parser, connection.reader, &scratch);
                        if (body_reader.interface.discardShort(max + 1)) |consumed| {
                            if (consumed > max) response.keepalive = false;
                        } else |_| {
                            if (connection.getReadError()) |e| if (e == error.Canceled) return error.Canceled;
                            response.keepalive = false;
                        }
                    } else {
                        response.keepalive = false;
                    }
                }

                if (self.shutting_down.load(.acquire)) {
                    response.keepalive = false;
                }

                try response.write();

                if (!response.keepalive) {
                    break;
                }

                parser.reset();
                request.reset();

                // If there's buffered data (pipelining), close connection - we don't support it
                if (connection.reader.end > connection.reader.seek) {
                    break;
                }

                _ = arena.reset(.retain_capacity);

                // Allocate fresh buffer for keepalive wait (previous buffer was freed by arena reset)
                connection.reader.buffer = request.arena.alloc(u8, self.config.request.buffer_size + 1024) catch |err| {
                    log.err("Failed to allocate read buffer: {}", .{err});
                    return err;
                };
                connection.reader.seek = 0;
                connection.reader.end = 0;

                if (self.config.timeout.keepalive) |duration| {
                    timeout.set(.fromMilliseconds(@intCast(duration.toMilliseconds())));
                }

                // Fill some data here, under the keepalive timeout
                connection.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown.* = false;
                        return;
                    },
                    error.ReadFailed => {
                        const e = connection.getReadError() orelse error.ReadFailed;
                        // Nothing is in flight between requests, so a peer
                        // that went away here has cost us nothing. The socket
                        // is already gone, so skip the shutdown syscall too.
                        if (Connection.isPeerGone(e)) {
                            needs_shutdown.* = false;
                            return;
                        }
                        return e;
                    },
                };
            }
        }
    };
}

test {
    _ = RequestParser;
}

/// A Connection with no real transport, in TLS mode, so the error accessors
/// can be driven directly. Only the `err` fields are read.
fn testTlsConnection() Connection {
    var conn: Connection = undefined;
    conn.initWriterForTesting(undefined);
    conn.tls_conn = .{ .input = undefined, .output = undefined, .cipher = undefined };
    conn.tls_reader.err = null;
    conn.tls_writer.err = null;
    return conn;
}

test "Connection: error accessors descend past the TLS layer's generic error" {
    if (!build_options.use_tls) return error.SkipZigTest;

    { // a transport write failure: TLS records WriteFailed, TCP has the cause
        var conn = testTlsConnection();
        conn.tls_writer.err = error.TransportWriteFailed;
        conn.tcp_writer.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.ConnectionResetByPeer, conn.getWriteError().?);
    }
    { // same on the read side
        var conn = testTlsConnection();
        conn.tls_reader.err = error.TransportReadFailed;
        conn.tcp_reader.err = error.Canceled;
        try std.testing.expectEqual(error.Canceled, conn.getReadError().?);
    }
}

test "Connection: a TLS-level failure is reported as itself" {
    if (!build_options.use_tls) return error.SkipZigTest;

    { // not a transport failure, so there is nothing below to descend to
        var conn = testTlsConnection();
        conn.tls_reader.err = error.TlsBadRecordMac;
        conn.tcp_reader.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.TlsBadRecordMac, conn.getReadError().?);
    }
    { // and with nothing recorded anywhere there is no error to report
        var conn = testTlsConnection();
        try std.testing.expectEqual(@as(?anyerror, null), conn.getWriteError());
    }
}

test "Connection: isPeerGone separates a departed peer from a real failure" {
    try std.testing.expect(Connection.isPeerGone(error.EndOfStream));
    try std.testing.expect(Connection.isPeerGone(error.ConnectionResetByPeer));
    // Closed between records: nothing was in flight, nothing was lost.
    try std.testing.expect(Connection.isPeerGone(error.TlsUnexpectedEof));
    // Closed mid-record: a record was cut, which is worth hearing about.
    try std.testing.expect(!Connection.isPeerGone(error.TlsTruncated));
    try std.testing.expect(!Connection.isPeerGone(error.TlsBadRecordMac));
    try std.testing.expect(!Connection.isPeerGone(error.Canceled));
}
