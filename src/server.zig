const std = @import("std");
const tls = @import("tls");
const build_options = @import("build_options");

const Router = @import("router.zig").Router;
const Action = @import("router.zig").Action;
const RequestParser = @import("parser.zig").RequestParser;
const RequestBodyReader = @import("parser.zig").RequestBodyReader;
const Request = @import("request.zig").Request;
const parseHeaders = @import("request.zig").parseHeaders;
const Headers = @import("http.zig").Headers;
const Response = @import("response.zig").Response;
const ServerConfig = @import("config.zig").ServerConfig;
const body_read_reserve = @import("config.zig").body_read_reserve;
const Executor = @import("middleware.zig").Executor;
const Middleware = @import("middleware.zig").Middleware;
const Transport = @import("transport.zig").Transport;
const have_auto_cancel = @import("deadline.zig").have_auto_cancel;
const Watch = @import("deadline.zig").Watch;
const Timer = @import("deadline.zig").Timer;
const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;

const log = std.log.scoped(.dusty);

/// How long the accept loop waits after failing for want of a file
/// descriptor or memory, doubling up to the cap. Short enough that a brief
/// shortage costs a little latency, capped so a sustained one settles into
/// one attempt a second rather than a spin.
const min_accept_backoff_ms = 5;
const max_accept_backoff_ms = 1000;

/// Walks all X-Forwarded-For fields as one comma-separated list. Repeated
/// fields are equivalent to one combined field, in their wire order.
const ForwardedForIterator = struct {
    headers: Headers.Iterator,
    addresses: ?std.mem.SplitIterator(u8, .scalar) = null,

    fn init(headers: *const Headers) ForwardedForIterator {
        return .{ .headers = headers.iterator() };
    }

    fn next(self: *ForwardedForIterator) ?[]const u8 {
        while (true) {
            if (self.addresses) |*addresses| {
                if (addresses.next()) |address| return std.mem.trim(u8, address, " \t");
                self.addresses = null;
            }

            const header = self.headers.next() orelse return null;
            if (std.ascii.eqlIgnoreCase(header.key, "X-Forwarded-For")) {
                self.addresses = std.mem.splitScalar(u8, header.value, ',');
            }
        }
    }
};

/// Returns the address `trusted_proxy_hops` hops away from this server. The
/// socket peer is hop zero, so hop one is the rightmost forwarded address.
/// Rejecting the whole chain on malformed input fails closed to the peer.
fn forwardedRemoteAddress(headers: *const Headers, trusted_proxy_hops: usize) ?std.Io.net.IpAddress {
    if (trusted_proxy_hops == 0) return null;

    var count: usize = 0;
    var counting = ForwardedForIterator.init(headers);
    while (counting.next()) |text| {
        if (text.len == 0) return null;
        count += 1;
    }
    if (count < trusted_proxy_hops) return null;

    const wanted = count - trusted_proxy_hops;
    var index: usize = 0;
    var selected: ?std.Io.net.IpAddress = null;
    var parsing = ForwardedForIterator.init(headers);
    while (parsing.next()) |text| : (index += 1) {
        const address = std.Io.net.IpAddress.parse(text, 0) catch return null;
        if (index == wanted) selected = address;
    }
    return selected;
}

fn remoteAddress(peer: std.Io.net.IpAddress, headers: *const Headers, trusted_proxy_hops: usize) std.Io.net.IpAddress {
    return forwardedRemoteAddress(headers, trusted_proxy_hops) orelse peer;
}

/// Borrowed view of the client-certificate settings, handed to each accepted
/// connection. The bundle is owned by the Server and outlives every connection.
const ClientAuthRef = struct {
    bundle: *std.crypto.Certificate.Bundle,
    mode: ServerConfig.Tls.ClientAuth.Mode,
};

/// Primed into a connection's request arena, so an ordinary request is
/// served without growing it. A request that needs more grows it once, and
/// the arena keeps what it grew to for the rest of the connection.
const request_arena_reserve = 8 * 1024;

/// Owns the reader/writer (and, for TLS, the whole TLS + underlying TCP
/// layer), their buffers and the request arena, for one accepted
/// connection. Initialized in place: `tls_conn` stores pointers into
/// `tcp_reader`/`tcp_writer`, and `tls_reader`/`tls_writer` store a pointer
/// back into `tls_conn`, so a `Connection` must never be moved after
/// `initPlain`/`initTls` runs.
pub const Connection = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,

    /// Per-request memory, reset between requests.
    arena: std.heap.ArenaAllocator,
    /// One allocation for what lives as long as the connection: the TLS
    /// record buffers, under TLS, and `read_buffer` after them.
    buffers: []u8,
    /// Where request heads are read. The parsed headers are slices into it,
    /// and what a head does not use is what the body reader reads into, so
    /// the reader's view of it shrinks as a request is parsed;
    /// `rewindReader` restores it for the next one.
    read_buffer: []u8,

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
    //
    // Public, and bare interfaces, so they can only report
    // `ReadFailed`/`WriteFailed`. That is allowed here because there is no
    // layer above them to lose the answer: `getReadError`/`getWriteError`
    // beside them resolve what actually failed.
    reader: *std.Io.Reader = undefined,
    writer: *std.Io.Writer = undefined,

    /// Whole before anything can fail, so `deinit` is safe after a failed
    /// init. `tls_buffers_len` is how much of `buffers` the TLS layer gets,
    /// ahead of the read buffer.
    fn init(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        request_buffer_size: usize,
        tls_buffers_len: usize,
    ) !void {
        self.* = .{
            .io = io,
            .stream = stream,
            .allocator = allocator,
            .arena = .init(allocator),
            .buffers = &.{},
            .read_buffer = &.{},
        };
        self.buffers = try allocator.alloc(u8, tls_buffers_len + request_buffer_size + body_read_reserve);
        self.read_buffer = self.buffers[tls_buffers_len..];

        // Reset keeps the memory, as one node the requests are then carved
        // from.
        _ = try self.arena.allocator().alloc(u8, request_arena_reserve);
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn initPlain(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        request_buffer_size: usize,
    ) !void {
        try self.init(allocator, io, stream, request_buffer_size, 0);
        self.tcp_reader = stream.reader(io, self.read_buffer);
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
        client_auth: ?ClientAuthRef,
    ) !void {
        try self.init(allocator, io, stream, request_buffer_size, tls.input_buffer_len + tls.output_buffer_len);

        // The tls.Connection points into these for the whole connection.
        const tcp_read_buffer = self.buffers[0..tls.input_buffer_len];
        const tcp_write_buffer = self.buffers[tls.input_buffer_len..][0..tls.output_buffer_len];

        self.tcp_reader = stream.reader(io, tcp_read_buffer);
        self.tcp_writer = stream.writer(io, tcp_write_buffer);
        self.tls_rng = .{ .io = io };
        self.tls_conn = try tls.server(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
            .auth = auth,
            // Built here rather than passed in as a tls.config.ClientAuth, so
            // tls_stub.zig does not have to mirror the type.
            .client_auth = if (client_auth) |ca| .{
                .root_ca = ca.bundle.*,
                .auth_type = switch (ca.mode) {
                    .request => .request,
                    .require => .require,
                },
            } else null,
            .now = std.Io.Clock.real.now(io),
            .rng = self.tls_rng.interface(),
        });
        self.tls_reader = self.tls_conn.?.reader(self.read_buffer);
        self.tls_writer = self.tls_conn.?.writer(&self.tls_cleartext_write_buffer);
        self.reader = &self.tls_reader.interface;
        self.writer = &self.tls_writer.interface;
    }

    /// Gives the reader the whole read buffer back for the next request.
    /// What the last request left unread is the start of the next one,
    /// pipelined behind it, and it moves to the front.
    pub fn rewindReader(self: *Connection) void {
        const r = self.reader;
        // `parseHeaders` left the reader a window past the head, with its
        // positions relative to that window.
        const head_len = self.read_buffer.len - r.buffer.len;
        r.buffer = self.read_buffer;
        r.seek += head_len;
        r.end += head_len;
        // Neither the stream reader nor the TLS reader overrides the
        // default rebase, which is a move within the buffer and cannot
        // fail.
        r.rebase(r.buffer.len) catch unreachable;
    }

    /// For tests: wraps a bare writer with no real TLS/TCP layer behind it.
    /// `tcp_writer.err` is left settable so a test can simulate the real
    /// error a write failure should surface.
    pub fn initWriterForTesting(self: *Connection, w: *std.Io.Writer) void {
        self.* = .{
            .io = undefined,
            .stream = undefined,
            .allocator = undefined,
            .arena = undefined,
            .buffers = &.{},
            .read_buffer = &.{},
            .reader = undefined,
            .writer = w,
        };
        self.tcp_reader.err = null;
        self.tcp_writer.err = null;
    }

    pub fn deinit(self: *Connection) void {
        self.arena.deinit();
        self.allocator.free(self.buffers);
    }

    /// A borrowed view of the layers above, for the parts of the library
    /// that are shared with the client and so can hold neither `Connection`.
    pub fn transport(self: *Connection) Transport {
        const has_tls = build_options.use_tls and self.tls_conn != null;
        return .{
            .reader = self.reader,
            .writer = self.writer,
            .tcp_reader = &self.tcp_reader,
            .tcp_writer = &self.tcp_writer,
            .tls_reader = if (has_tls) &self.tls_reader else null,
            .tls_writer = if (has_tls) &self.tls_writer else null,
        };
    }

    pub const ReadError = Transport.ReadError;
    pub const WriteError = Transport.WriteError;

    /// The real error behind a generic `error.ReadFailed`, if any was recorded.
    pub fn getReadError(self: *Connection) ?ReadError {
        return self.transport().getReadError();
    }

    /// The real error behind a generic `error.WriteFailed`, if any was
    /// recorded.
    pub fn getWriteError(self: *Connection) ?WriteError {
        return self.transport().getWriteError();
    }

    pub const isPeerGone = Transport.isPeerGone;

    /// Whether a read or write on this connection failed because the peer
    /// is gone. Asked instead of judging an error by its name: a handler's
    /// own `EndOfStream`, from a file or from a std helper at the end of
    /// the body, is spelled like a disconnect and is not one.
    pub fn peerGone(self: *Connection) bool {
        if (self.getWriteError()) |e| if (isPeerGone(e)) return true;
        if (self.getReadError()) |e| if (isPeerGone(e)) return true;
        return false;
    }
};

/// The one reply that cannot go through `Response`: what overran is the head
/// that would have said how to frame it. Fixed bytes instead, and
/// `Connection: close`, because the rest of that head is still queued on the
/// socket and there is no framing to skip it by.
fn sendServiceUnavailable(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 503 Service Unavailable\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    return w.flush();
}

/// How much of a refused request is thrown away before hanging up on it,
/// and how long that is given: a peer that has read the answer hangs up
/// within a round trip, and the request deadline may be off.
const refused_drain_limit: usize = 64 * 1024;
const refused_drain_timeout: std.Io.Duration = .fromSeconds(1);

fn sendHeadersTooLarge(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    return w.flush();
}

pub const Address = @import("config.zig").Address;
pub const Listener = @import("config.zig").Listener;

fn setRequestTimeout(context: *anyopaque, io: std.Io, timeout: std.Io.Timeout) void {
    const timer: *Timer = @ptrCast(@alignCast(context));
    timer.set(io, timeout);
}

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
        active_connections: std.atomic.Value(u32),
        /// What the drain waits on: connections with a request in flight,
        /// from accept or the first byte of a request until they go back to
        /// waiting for one, and whether the drain is on. One word, so a
        /// request arriving as the drain starts is either counted before
        /// the drain looks or refused after seeing the flag: the two
        /// updates are ordered by the word, whichever comes second sees the
        /// first. A connection waiting between requests is not counted; it
        /// has nothing to lose to the cancel that follows the drain.
        busy: std.atomic.Value(Busy),
        /// The first listener's bound address, once `ready` is set. A
        /// listener given port zero has its real port here.
        address: Address,
        /// Every listener's bound address, in `config.listen` order. Filled
        /// in before `ready` is set, and empty again once `run` has
        /// returned.
        addresses: []const Address = &.{},
        ready: std.Io.Event,
        _middleware_registry: std.SinglyLinkedList,

        /// A listener while `run` serves it: the socket, and the TLS
        /// material every connection accepted on it shares.
        const ActiveListener = struct {
            config: *const Listener,
            address: Address,
            server: std.Io.net.Server,
            tls_auth: ?tls.config.CertKeyPair = null,
            tls_client_ca: ?std.crypto.Certificate.Bundle = null,
            client_auth_mode: ServerConfig.Tls.ClientAuth.Mode = .require,
            /// Why its accept loop gave up, once it has.
            err: ?anyerror = null,

            fn freeTls(l: *ActiveListener, allocator: std.mem.Allocator) void {
                if (build_options.use_tls) {
                    if (l.tls_auth) |*auth| {
                        auth.deinit(allocator);
                        l.tls_auth = null;
                    }
                    if (l.tls_client_ca) |*bundle| {
                        bundle.deinit(allocator);
                        l.tls_client_ca = null;
                    }
                }
            }

            fn close(l: *ActiveListener, io: std.Io, allocator: std.mem.Allocator) void {
                l.server.deinit(io);
                l.freeTls(allocator);
            }
        };

        const Busy = packed struct(u32) {
            count: u31 = 0,
            draining: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ServerConfig, ctx: if (Ctx == void) void else *Ctx) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .active_connections = std.atomic.Value(u32).init(0),
                .busy = .init(.{}),
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

        /// Accepts on every listener in `config.listen` until canceled, then
        /// drains the connections in flight.
        pub fn run(self: *Self) !void {
            const listeners = self.config.listen;
            if (listeners.len == 0) {
                log.err("config.listen is empty, so no connection could ever be served", .{});
                return error.NoListeners;
            }
            if (self.config.max_connections) |max| {
                if (max == 0) {
                    log.err("config.max_connections is 0, so no connection could ever be served", .{});
                    return error.NoConnectionsAllowed;
                }
            }

            const active = try self.allocator.alloc(ActiveListener, listeners.len);
            defer self.allocator.free(active);
            const addresses = try self.allocator.alloc(Address, listeners.len);
            defer self.allocator.free(addresses);
            var opened: usize = 0;
            defer for (active[0..opened]) |*l| l.close(self.io, self.allocator);
            for (listeners, active, addresses) |*cfg, *l, *address| {
                l.* = try self.open(cfg);
                opened += 1;
                address.* = l.address;
            }

            self.addresses = addresses;
            defer self.addresses = &.{};
            self.address = addresses[0];
            self.ready.set(self.io);

            for (active) |*l| log.info("Listening on {f}", .{l.address});

            var connections: std.Io.Group = .init;
            defer {
                _ = self.busy.fetchOr(.{ .draining = true }, .release);
                connections.cancel(self.io);
            }

            // Set by the first accept loop to give up; a cancel arrives
            // through the wait instead. Either way the accept loops are
            // stopped before the connections are, so nothing new arrives
            // while the drain waits, and the drain runs either way: a
            // listener failing takes the whole server down, and the
            // requests in flight on the others deserve the same chance to
            // finish as on a shutdown.
            var stopped: std.Io.Event = .unset;
            var accepting: std.Io.Group = .init;
            defer accepting.cancel(self.io);
            for (active) |*l| {
                accepting.concurrent(self.io, acceptLoop, .{ self, l, &connections, &stopped }) catch |err| {
                    log.err("Failed to spawn the accept loop for {f}: {}", .{ l.address, err });
                    // The loops already running may have accepted by now.
                    accepting.cancel(self.io);
                    self.drainConnections();
                    return err;
                };
            }

            stopped.wait(self.io) catch |err| switch (err) {
                error.Canceled => {
                    accepting.cancel(self.io);
                    self.drainConnections();
                    return err;
                },
            };

            accepting.cancel(self.io);
            self.drainConnections();
            for (active) |*l| {
                if (l.err) |err| return err;
            }
            // Cannot happen: `stopped` is only set by an accept loop that
            // stored its error first, and every loop was joined above.
            unreachable;
        }

        /// Loads the listener's TLS material and binds its socket.
        fn open(self: *Self, cfg: *const Listener) !ActiveListener {
            var l: ActiveListener = .{ .config = cfg, .address = cfg.address, .server = undefined };
            errdefer l.freeTls(self.allocator);

            if (cfg.tls) |tls_cfg| {
                if (!build_options.use_tls) {
                    log.err("tls is set but the library was built with use_tls=false", .{});
                    return error.TlsNotConfigured;
                }
                if (tls_cfg.client_auth) |client_auth| {
                    if (client_auth.ca == .none) {
                        log.err("tls.client_auth.ca is .none, so no client certificate could ever verify", .{});
                        return error.NoCertificateAuthority;
                    }
                    l.client_auth_mode = client_auth.mode;
                }

                const dir = tls_cfg.dir orelse std.Io.Dir.cwd();
                l.tls_auth = tls.config.CertKeyPair.fromFilePath(
                    self.allocator,
                    self.io,
                    dir,
                    tls_cfg.cert_path,
                    tls_cfg.key_path,
                ) catch |err| {
                    log.err("Failed to load TLS certificate/key: {}", .{err});
                    return err;
                };

                if (tls_cfg.client_auth) |client_auth| {
                    l.tls_client_ca = client_auth.ca.load(self.allocator, self.io) catch |err| {
                        log.err("Failed to load client certificate authorities: {}", .{err});
                        return err;
                    };
                }
            }

            l.server = switch (cfg.address) {
                .ip => |ip| try ip.listen(self.io, .{
                    .kernel_backlog = cfg.kernel_backlog,
                    .reuse_address = cfg.reuse_address,
                }),
                .unix => |unix| try unix.listen(self.io, .{ .kernel_backlog = cfg.kernel_backlog }),
            };
            if (cfg.address == .ip) l.address = .{ .ip = l.server.socket.address };
            return l;
        }

        /// A cancel is the normal end and is reported to nobody: the group
        /// swallows it, and `run` learns of it from its own wait. Anything
        /// else is the listener failing, and stops the whole run.
        fn acceptLoop(
            self: *Self,
            l: *ActiveListener,
            connections: *std.Io.Group,
            stopped: *std.Io.Event,
        ) std.Io.Cancelable!void {
            self.acceptConnections(l, connections) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    log.err("Listener {f} failed: {}", .{ l.address, err });
                    l.err = err;
                    stopped.set(self.io);
                },
            };
        }

        fn acceptConnections(self: *Self, l: *ActiveListener, connections: *std.Io.Group) !void {
            // Grows while accepting keeps failing for want of resources, and
            // is reset by the first connection that gets through.
            var backoff_ms: u64 = 0;

            while (true) {
                try self.waitForConnectionSlot();

                const stream = l.server.accept(self.io) catch |err| switch (err) {
                    // One connection went away between its SYN and our
                    // accept, which says nothing about the listener. Routine
                    // on a public address, where clients reset and scanners
                    // probe, so it is not worth a log line or a pause.
                    error.ConnectionAborted => continue,
                    // The machine is out of something, for now. Sleeping and
                    // trying again turns that into latency; returning would
                    // turn a condition that clears on its own into an outage
                    // that needs a restart.
                    error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded,
                    error.SystemResources,
                    error.WouldBlock,
                    => {
                        backoff_ms = if (backoff_ms == 0) min_accept_backoff_ms else @min(backoff_ms * 2, max_accept_backoff_ms);
                        log.warn("Accept failed: {}; retrying in {d}ms", .{ err, backoff_ms });
                        // A cancel is taken here, not deferred to the accept
                        // above with `recancel`. That accept keeps failing
                        // for its own reason -- the fd table is full, which
                        // is why we are in the backoff -- and an operation
                        // that completes with a result of its own has the
                        // cancellation re-armed rather than reported, so
                        // deferring would livelock.
                        try self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake);
                        continue;
                    },
                    else => return err,
                };
                backoff_ms = 0;

                self.reserveConnectionSlot() catch |err| {
                    stream.close(self.io);
                    return err;
                };
                _ = self.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
                connections.concurrent(self.io, handleConnectionWrapper, .{ self, l, stream }) catch |err| {
                    log.err("Failed to spawn connection handler: {}", .{err});
                    self.finishRequest();
                    self.releaseConnectionSlot();
                    stream.close(self.io);
                    continue;
                };
            }
        }

        /// Waits for the connections already in flight, once the accept
        /// loops have been stopped.
        ///
        /// Runs under cancel protection: this is the shutdown, and a further
        /// cancel arriving mid-drain would abandon connections rather than
        /// finish with them. What bounds it is its own policy below, not
        /// whoever asked it to stop.
        ///
        /// Infallible, so that `run` reports what stopped it rather than a
        /// detail of how the drain went. Connections that
        /// outlast the wait are logged and left to the caller's deferred
        /// `group.cancel`, which tears them down either way.
        fn drainConnections(self: *Self) void {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);

            log.info("Graceful shutdown requested", .{});
            _ = self.busy.fetchOr(.{ .draining = true }, .acq_rel);

            // Turned into a deadline once, so the budget covers the drain as
            // a whole. A per-wait duration would restart it every time a
            // connection closed, and a steady trickle would then hold the
            // shutdown open indefinitely.
            const timeout: std.Io.Timeout = if (self.config.timeout.shutdown) |duration|
                std.Io.Timeout.toDeadline(.{ .duration = .{ .raw = duration, .clock = .awake } }, self.io)
            else
                .none;

            while (true) {
                const state = self.busy.load(.acquire);
                const remaining = state.count;
                if (remaining == 0) return;

                if (timeout.toTimestamp(self.io)) |deadline| {
                    if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) {
                        log.warn("Shutdown timed out with {d} request(s) still in flight", .{remaining});
                        return;
                    }
                }

                log.info("Waiting for {} in-flight request(s) to finish", .{remaining});
                // Wakes when a request finishes, or when the deadline
                // arrives; the loop above decides which happened. Spurious
                // wakeups just re-read the count.
                self.io.futexWaitTimeout(Busy, &self.busy.raw, state, timeout) catch |err| switch (err) {
                    // Cannot happen: protection is blocked for this whole
                    // function, so no Io call here is a cancelation point.
                    error.Canceled => unreachable,
                };
            }
        }

        /// Blocks while every connection slot is taken. Not accepting is the
        /// backpressure: what arrives meanwhile waits in the kernel's accept
        /// queue, `Listener.kernel_backlog` deep.
        fn waitForConnectionSlot(self: *Self) std.Io.Cancelable!void {
            const max = self.config.max_connections orelse return;
            while (true) {
                const active = self.active_connections.load(.acquire);
                if (active < max) return;
                log.debug("At the {d} connection cap; waiting for a slot", .{max});
                try self.io.futexWait(u32, &self.active_connections.raw, active);
            }
        }

        /// Takes the slot for a connection just accepted. The check above is
        /// what keeps a loop from accepting at the cap, but it is not one
        /// step with this, and one accept loop per listener races for the
        /// same slots. A loop that lost the race waits here, holding its
        /// connection the way the backlog would have, so the cap is exact.
        fn reserveConnectionSlot(self: *Self) std.Io.Cancelable!void {
            const max = self.config.max_connections orelse {
                _ = self.active_connections.fetchAdd(1, .acq_rel);
                return;
            };
            var active = self.active_connections.load(.acquire);
            while (true) {
                if (active >= max) {
                    log.debug("At the {d} connection cap; waiting for a slot", .{max});
                    try self.io.futexWait(u32, &self.active_connections.raw, active);
                    active = self.active_connections.load(.acquire);
                    continue;
                }
                active = self.active_connections.cmpxchgWeak(active, active + 1, .acq_rel, .acquire) orelse return;
            }
        }

        /// Wakes every accept loop waiting for a slot. Waking one is not
        /// enough: it may be a loop that goes back to blocking in `accept`
        /// on an idle listener, while another holds a connection it cannot
        /// serve until it is woken.
        fn releaseConnectionSlot(self: *Self) void {
            _ = self.active_connections.fetchSub(1, .acq_rel);
            self.io.futexWake(u32, &self.active_connections.raw, std.math.maxInt(u32));
        }

        /// Wakes the drain when this was the last one: zero is the only
        /// count it acts on, so the others are not worth a syscall.
        fn finishRequest(self: *Self) void {
            const was = self.busy.fetchSub(.{ .count = 1 }, .acq_rel);
            if (was.count == 1) self.io.futexWake(Busy, &self.busy.raw, 1);
        }

        const RequestWait = enum {
            arrived,
            peer_gone,
            /// The drain is on. The peer was told so, with a 503, and the
            /// connection is done.
            refused,
        };

        /// Waits for the first byte of a request, with nothing in flight:
        /// the drain does not wait for a connection here, and the cancel
        /// that follows it closes the socket cleanly.
        fn waitForRequest(self: *Self, connection: *Connection, busy: *bool) !RequestWait {
            busy.* = false;
            self.finishRequest();

            connection.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return .peer_gone,
                error.ReadFailed => {
                    const e = connection.getReadError() orelse error.Unexpected;
                    // Nothing is in flight between requests, so a peer that
                    // went away here has cost us nothing.
                    if (Connection.isPeerGone(e)) return .peer_gone;
                    return e;
                },
            };

            const was = self.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            busy.* = true;
            if (was.draining) {
                busy.* = false;
                self.finishRequest();
                sendServiceUnavailable(connection.writer) catch
                    return connection.getWriteError() orelse error.Unexpected;
                return .refused;
            }
            return .arrived;
        }

        fn handleConnectionWrapper(self: *Self, l: *ActiveListener, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            if (comptime have_auto_cancel) return runConnection(self, l, stream, null);

            if (self.config.timeout.request == null and self.config.timeout.keepalive == null) {
                return runConnection(self, l, stream, null);
            }

            var watch: Watch = .{};
            var future = self.io.concurrent(runConnection, .{ self, l, stream, &watch }) catch |err| {
                log.warn("No task to watch the connection deadline: {}; refusing", .{err});
                self.finishRequest();
                self.releaseConnectionSlot();
                stream.close(self.io);
                return;
            };
            defer future.cancel(self.io);

            watch.wait(self.io) catch |err| switch (err) {
                error.Timeout => {
                    log.debug("Connection exceeded its deadline", .{});
                    return;
                },
                error.Canceled => return error.Canceled,
            };

            // Collected here rather than by the defer, which would put a
            // cancelation request to a task partway through its teardown.
            future.await(self.io);
        }

        /// Runs on this task under zio, on a task of its own otherwise.
        fn runConnection(self: *Self, l: *ActiveListener, stream: std.Io.net.Stream, watch: ?*Watch) void {
            defer if (watch) |w| w.finish(self.io);

            handleConnection(self, l, stream, watch) catch |err| {
                if (err == error.Canceled) {
                    log.debug("Connection canceled", .{});
                    return;
                }
                // A peer disappearing mid-request is ordinary and would drown
                // out the failures worth looking at.
                if (Connection.isPeerGone(err)) {
                    log.debug("Connection closed by peer: {}", .{err});
                } else {
                    log.err("Connection error: {}", .{err});
                }
            };
        }

        /// Hangs up on a peer whose request was refused before it was all
        /// read, so the peer still gets the answer. Closing with input
        /// unread makes the kernel send a reset instead of a FIN, and a
        /// Windows peer throws the buffered answer away when a reset
        /// arrives. So the send side is shut first, which tells the peer
        /// there is nothing more to wait for, and what it sent is thrown
        /// away until it hangs up, or `refused_drain_timeout` passes, or
        /// `refused_drain_limit` bytes for a peer that keeps sending.
        /// Without a deadline to arm, the wait could be held open, so the
        /// close stays immediate, reset and all.
        fn hangUpOnRefused(self: *Self, connection: *Connection, timer: *Timer) !void {
            if (!timer.canBound()) return;
            timer.set(self.io, .{ .duration = .{ .raw = refused_drain_timeout, .clock = .awake } });
            defer timer.clear(self.io);
            connection.stream.shutdown(self.io, .send) catch |err| switch (err) {
                // Already gone: nothing left to throw away.
                error.SocketUnconnected, error.ConnectionResetByPeer, error.ConnectionAborted => return,
                else => |e| return e,
            };
            _ = connection.reader.discardShort(refused_drain_limit) catch {
                const cause = connection.getReadError() orelse error.Unexpected;
                // The peer hanging up is the end this waits for. The
                // deadline arrives as a cancel, and stays one.
                if (Connection.isPeerGone(cause)) return;
                return cause;
            };
        }

        fn handleConnection(self: *Self, l: *ActiveListener, stream: std.Io.net.Stream, watch: ?*Watch) !void {
            defer self.releaseConnectionSlot();

            // Counted since accept, so a handshake in progress is waited for
            // like a request. Handed back and taken again in `waitForRequest`.
            var busy = true;
            defer if (busy) self.finishRequest();

            defer stream.close(self.io);

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(self.io, .both) catch |err| {
                if (err == error.SocketUnconnected) {
                    log.debug("Failed to shutdown client connection: {}", .{err});
                } else {
                    log.warn("Failed to shutdown client connection: {}", .{err});
                }
            };

            var connection: Connection = undefined;
            defer connection.deinit();

            var timer: Timer = .init(watch);
            defer timer.clear(self.io);

            // When the listener is TLS, upgrade the accepted stream and run
            // the request loop over the cleartext reader/writer. Otherwise
            // run it directly over the raw stream.
            if (build_options.use_tls) {
                if (l.tls_auth) |*auth| {
                    // The handshake is the one part of a connection's life
                    // the request loop's timeout cannot cover, since that
                    // loop does not exist yet. A peer that opens a socket
                    // and then stalls mid-handshake would otherwise hold a
                    // task and the connection's whole buffer reservation
                    // for as long as it likes -- cheaper for it than a
                    // slow request, which is bounded.
                    {
                        defer timer.clear(self.io);
                        self.armTimer(&timer, self.config.timeout.request);

                        const client_auth: ?ClientAuthRef = if (l.tls_client_ca) |*bundle| .{
                            .bundle = bundle,
                            .mode = l.client_auth_mode,
                        } else null;

                        connection.initTls(self.allocator, self.io, stream, self.config.request.buffer_size, auth, client_auth) catch |err| {
                            // tls.zig only saw the ciphertext reader or
                            // writer fail generically, so the cause is a
                            // layer down -- and when the handshake ran out
                            // of time, that cause is the cancel.
                            const cause = switch (err) {
                                error.ReadFailed => connection.getReadError() orelse err,
                                error.WriteFailed => connection.getWriteError() orelse err,
                                else => err,
                            };
                            // Nothing was negotiated, so there is no TLS
                            // session to shut down politely either way.
                            needs_shutdown = false;
                            if (cause == error.Canceled) {
                                log.debug("TLS handshake canceled", .{});
                                return error.Canceled;
                            }
                            if (Connection.isPeerGone(cause)) {
                                log.debug("TLS handshake abandoned by peer: {}", .{cause});
                            } else {
                                log.err("TLS handshake failed: {}", .{cause});
                            }
                            return;
                        };
                    }

                    return self.handleRequests(l, &connection, &needs_shutdown, &timer, &busy);
                }
            }

            try connection.initPlain(self.allocator, self.io, stream, self.config.request.buffer_size);
            return self.handleRequests(l, &connection, &needs_shutdown, &timer, &busy);
        }

        /// Cleared when `duration` is unset, so an earlier deadline does not
        /// carry into a wait meant to be unbounded.
        fn armTimer(self: *Self, timer: *Timer, duration: ?std.Io.Duration) void {
            if (duration) |d| {
                timer.set(self.io, .{ .duration = .{ .raw = d, .clock = .awake } });
            } else {
                timer.clear(self.io);
            }
        }

        /// Runs the HTTP request loop over a connection: each request is
        /// parsed, served and answered before the next is looked at, so
        /// pipelined requests are answered in order without any more
        /// machinery than a keepalive connection needs.
        fn handleRequests(
            self: *Self,
            l: *ActiveListener,
            connection: *Connection,
            needs_shutdown: *bool,
            timer: *Timer,
            busy: *bool,
        ) !void {
            var request: Request = .{
                .arena = connection.arena.allocator(),
                .io = self.io,
                .transport = connection.transport(),
                .parser = undefined,
                .config = self.config.request,
                .remote_address = connection.stream.socket.address,
                .listener = l.config,
                .secure = build_options.use_tls and l.tls_auth != null,
                ._timeout_context = timer,
                ._set_timeout = setRequestTimeout,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            while (true) {
                // Nothing buffered means the next request has not begun.
                // The first is waited for under the request deadline, which
                // runs from accept; a later one under the keepalive
                // deadline, and its request deadline runs from arrival. A
                // request pipelined behind the last one is already here.
                const first = request_count == 0;
                if (connection.reader.bufferedLen() == 0) {
                    self.armTimer(timer, if (first) self.config.timeout.request else self.config.timeout.keepalive);
                    switch (try self.waitForRequest(connection, busy)) {
                        .arrived => {},
                        // The socket is already gone, so skip the shutdown
                        // syscall too.
                        .peer_gone => {
                            needs_shutdown.* = false;
                            return;
                        },
                        .refused => return,
                    }
                }
                if (!first) self.armTimer(timer, self.config.timeout.request);
                request_count += 1;

                parseHeaders(connection.reader, &parser) catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown.* = false;
                        return;
                    },
                    error.ReadFailed => return connection.getReadError() orelse error.Unexpected,
                    error.HeadersTooLarge => {
                        log.debug("Request head did not fit in {d} bytes", .{self.config.request.buffer_size});
                        sendHeadersTooLarge(connection.writer) catch
                            return connection.getWriteError() orelse error.Unexpected;
                        needs_shutdown.* = false;
                        try self.hangUpOnRefused(connection, timer);
                        return;
                    },
                    error.TooManyHeaders => {
                        log.debug("Request had more than {d} headers", .{self.config.request.max_header_count});
                        sendHeadersTooLarge(connection.writer) catch
                            return connection.getWriteError() orelse error.Unexpected;
                        needs_shutdown.* = false;
                        try self.hangUpOnRefused(connection, timer);
                        return;
                    },
                    else => |e| return e,
                };

                // This is per request, not per connection: a keepalive
                // connection may carry a different forwarding chain on every
                // request. Starting from the socket peer also makes an absent
                // or invalid chain fail closed instead of retaining the last
                // request's forwarded address.
                request.remote_address = remoteAddress(
                    connection.stream.socket.address,
                    &request.headers,
                    self.config.trusted_proxy_hops,
                );

                log.debug("Received: {f} {s}", .{ request.method, request.url });

                var response = try Response.init(request.arena, connection, self.config.request.max_header_count);
                response.head = request.method == .head;
                response.http10 = request.version_major == 1 and request.version_minor == 0;
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

                const found = self.router.findHandler(&request) catch |err| switch (err) {
                    // The request's own doing, and the connection is fine.
                    error.InvalidEscapeSequence, error.TooManyQueryParams => {
                        response.status = .bad_request;
                        response.keepalive = false;
                        try response.write();
                        return;
                    },
                    else => |e| return e,
                };
                var executor = Executor(Ctx){
                    .req = &request,
                    .res = &response,
                    .ctx = self.ctx,
                    .action = if (found) |r| r.action else null,
                    .middlewares = if (found) |r| r.middlewares else self.router.middlewares,
                };
                executor.run() catch |err| switch (err) {
                    error.ReadFailed => return connection.getReadError() orelse error.Unexpected,
                    error.WriteFailed => return connection.getWriteError() orelse error.Unexpected,
                    else => |e| return e,
                };

                if (!parser.isBodyComplete()) {
                    const max = self.config.request.max_body_size;
                    const drainable = blk: {
                        // The peer is holding the body until it hears 100
                        // Continue, and nothing asked for it. There is
                        // nothing to drain, and a read would wait for it. A
                        // peer that sent the body anyway is not waiting, and
                        // its body is drained like any other.
                        if (request.expects_continue and connection.reader.bufferedLen() == 0) break :blk false;
                        // What the wire carried, which is what there is left
                        // to throw away -- and still readable after decoding
                        // took the header off.
                        const n = request.content_length orelse break :blk false;
                        break :blk n <= max;
                    };
                    if (drainable) {
                        var scratch: [4096]u8 = undefined;
                        // No decoding: this is throwing the body away to get
                        // back to the connection, and `max` bounds what the
                        // peer sent rather than what it would decode to.
                        var body_reader = RequestBodyReader.init(&parser, connection.transport(), &scratch);
                        if (body_reader.interface.discardShort(max + 1)) |consumed| {
                            if (consumed > max) response.keepalive = false;
                        } else |_| {
                            // A cancel is the request timing out, not a body
                            // worth giving up on quietly.
                            if (body_reader.err) |e| if (e == error.Canceled) return error.Canceled;
                            response.keepalive = false;
                        }
                    } else {
                        response.keepalive = false;
                    }
                }

                if (self.busy.load(.acquire).draining) {
                    response.keepalive = false;
                }

                try response.write();

                if (!response.keepalive) {
                    break;
                }

                parser.reset();
                request.reset();
                _ = connection.arena.reset(.retain_capacity);
                connection.rewindReader();
            }
        }
    };
}

test {
    _ = RequestParser;
}

test "trusted proxy hops select X-Forwarded-For from the right" {
    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.add("X-Forwarded-For", "192.0.2.99, 203.0.113.10");
    try headers.add("x-forwarded-for", "198.51.100.7");

    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 4321);

    const direct = remoteAddress(peer, &headers, 0);
    try std.testing.expect(direct.ip4.eql(peer.ip4));

    const one = remoteAddress(peer, &headers, 1);
    try std.testing.expectEqual([4]u8{ 198, 51, 100, 7 }, one.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 0), one.ip4.port);

    const two = remoteAddress(peer, &headers, 2);
    try std.testing.expectEqual([4]u8{ 203, 0, 113, 10 }, two.ip4.bytes);

    const three = remoteAddress(peer, &headers, 3);
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 99 }, three.ip4.bytes);

    // More trusted hops than the proxy supplied cannot establish a client
    // address, so it is safer to expose the connected peer.
    const too_short = remoteAddress(peer, &headers, 4);
    try std.testing.expect(too_short.ip4.eql(peer.ip4));

    // A malformed address anywhere in the chain makes its ordering
    // ambiguous/untrustworthy and likewise falls back to the peer.
    try headers.put("X-Forwarded-For", "not-an-address, 203.0.113.10");
    const malformed = remoteAddress(peer, &headers, 2);
    try std.testing.expect(malformed.ip4.eql(peer.ip4));
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
        conn.tls_writer.err = error.WriteFailed;
        conn.tcp_writer.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.ConnectionResetByPeer, conn.getWriteError().?);
    }
    { // same on the read side
        var conn = testTlsConnection();
        conn.tls_reader.err = error.ReadFailed;
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

test "Connection: the placeholders it descends past stay out of its error sets" {
    // `ReadFailed`/`WriteFailed` mean only "the layer below failed", which
    // is what the accessors exist to look past. They must not survive into
    // what a caller can be handed.
    inline for (@typeInfo(Connection.ReadError).error_set.?) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, "ReadFailed"));
    }
    inline for (@typeInfo(Connection.WriteError).error_set.?) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, "WriteFailed"));
    }
}

test "Connection: isPeerGone separates a departed peer from a real failure" {
    try std.testing.expect(Connection.isPeerGone(error.EndOfStream));
    try std.testing.expect(Connection.isPeerGone(error.ConnectionResetByPeer));
    // Closed mid-record: a record was cut, which is worth hearing about.
    try std.testing.expect(!Connection.isPeerGone(error.TlsConnectionTruncated));
    try std.testing.expect(!Connection.isPeerGone(error.TlsBadRecordMac));
    try std.testing.expect(!Connection.isPeerGone(error.Canceled));
}
