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
const body_read_reserve = @import("config.zig").body_read_reserve;
const Executor = @import("middleware.zig").Executor;
const Middleware = @import("middleware.zig").Middleware;
const Transport = @import("transport.zig").Transport;
const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;

const log = std.log.scoped(.dusty);

/// How long the accept loop waits after failing for want of a file
/// descriptor or memory, doubling up to the cap. Short enough that a brief
/// shortage costs a little latency, capped so a sustained one settles into
/// one attempt a second rather than a spin.
const min_accept_backoff_ms = 5;
const max_accept_backoff_ms = 1000;

/// Borrowed view of the client-certificate settings, handed to each accepted
/// connection. The bundle is owned by the Server and outlives every connection.
const ClientAuthRef = struct {
    bundle: *std.crypto.Certificate.Bundle,
    mode: ServerConfig.Tls.ClientAuth.Mode,
};

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
        client_auth: ?ClientAuthRef,
    ) !void {
        self.* = .{ .io = io, .stream = stream };
        self.arena = .init(allocator);

        // Aim for a single backing allocation per connection: prime the
        // arena with room for the two TLS record buffers plus a working
        // budget, then recycle it (reset keeps the memory). The TLS buffers
        // and the per-request arena are then carved from that one
        // allocation; only unusually large requests grow it.
        const conn_reserve = tls.input_buffer_len + tls.output_buffer_len + 2 * (request_buffer_size + body_read_reserve);
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
};

/// The one reply that cannot go through `Response`: what overran is the head
/// that would have said how to frame it. Fixed bytes instead, and
/// `Connection: close`, because the rest of that head is still queued on the
/// socket and there is no framing to skip it by.
fn sendHeadersTooLarge(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    return w.flush();
}

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

/// Whether the injected `zio` can arm a timer against the running task. The
/// stub says so by declaring `is_stub`; the real package does not.
const have_auto_cancel = !@hasDecl(zio, "is_stub");

/// A deadline one task publishes and another waits on.
///
/// The watcher sleeps on `generation`, which every re-arm and the finish bump
/// before waking it. That order is what makes the wait lossless: a re-arm
/// racing the watcher leaves the word different from what the wait expects,
/// so it returns rather than sleeping on stale terms.
const Watch = struct {
    generation: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    /// Guarded by `mutex`. Never `.duration`: `set` pins one to the moment it
    /// was published.
    timeout: std.Io.Timeout = .none,
    /// Guarded by `mutex`.
    finished: bool = false,

    const State = struct {
        timeout: std.Io.Timeout,
        finished: bool,
    };

    fn wake(self: *Watch, io: std.Io) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
        io.futexWake(u32, &self.generation.raw, 1);
    }

    fn published(self: *Watch, io: std.Io) State {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{ .timeout = self.timeout, .finished = self.finished };
    }

    fn set(self: *Watch, io: std.Io, timeout: std.Io.Timeout) void {
        // A duration runs from the call that published it, and the watcher may
        // not read it until much later.
        const deadline = timeout.toDeadline(io);
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.timeout = deadline;
        }
        self.wake(io);
    }

    fn arm(self: *Watch, io: std.Io, duration: std.Io.Duration) void {
        self.set(io, .{ .duration = .{ .raw = duration, .clock = .awake } });
    }

    fn disarm(self: *Watch, io: std.Io) void {
        self.set(io, .none);
    }

    fn finish(self: *Watch, io: std.Io) void {
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.finished = true;
        }
        self.wake(io);
    }

    /// Blocks until the connection finishes, or `error.Timeout` if it
    /// overruns the deadline it last published.
    fn wait(self: *Watch, io: std.Io) (std.Io.Cancelable || std.Io.Timeout.Error)!void {
        while (true) {
            // Captured before the snapshot, so a `set` that lands in between
            // is one the wait below refuses to sleep through.
            const generation = self.generation.load(.acquire);
            const state = self.published(io);
            if (state.finished) return;

            // The wait does not report why it returned, and `generation` is
            // only its wakeup token: `set` publishes the deadline before the
            // bump, so an unchanged generation does not mean an unchanged
            // deadline. Every wakeup comes back here and judges the deadline
            // published now, never the one it went to sleep on.
            if (state.timeout.toTimestamp(io)) |deadline| {
                if (std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.gte, deadline)) {
                    return error.Timeout;
                }
            }

            try io.futexWaitTimeout(u32, &self.generation.raw, generation, state.timeout);
        }
    }
};

/// Bounds how long a connection may spend on any one blocking step.
///
/// zio arms a timer against the running task. `std.Io` has no deadline for a
/// stream read, only cancelation, so elsewhere the deadline goes to a second
/// task that cancels this one when it passes.
const Timer = if (have_auto_cancel) struct {
    inner: zio.AutoCancel = .init,

    fn init(_: ?*Watch) @This() {
        return .{};
    }

    fn set(self: *@This(), _: std.Io, timeout: std.Io.Timeout) void {
        // `Timeout.fromStd` keeps the value clockless and `Clock.fromStdTimeout`
        // carries the clock, which is how zio wants the two halves.
        self.inner.setClock(.fromStd(timeout), .fromStdTimeout(timeout));
    }

    fn clear(self: *@This(), _: std.Io) void {
        self.inner.clear();
    }
} else struct {
    /// Null when no deadline was configured.
    watch: ?*Watch = null,

    fn init(w: ?*Watch) @This() {
        return .{ .watch = w };
    }

    fn set(self: *@This(), io: std.Io, timeout: std.Io.Timeout) void {
        const w = self.watch orelse return;
        w.set(io, timeout);
    }

    fn clear(self: *@This(), io: std.Io) void {
        const w = self.watch orelse return;
        w.disarm(io);
    }
};

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
        shutting_down: std.atomic.Value(bool),
        active_connections: std.atomic.Value(u32),
        address: Address,
        ready: std.Io.Event,
        _middleware_registry: std.SinglyLinkedList,
        /// Server certificate/key, loaded once in listen() when config.tls is set.
        tls_auth: ?tls.config.CertKeyPair = null,
        /// CAs for verifying client certificates, loaded alongside tls_auth
        /// when config.tls.client_auth is set.
        tls_client_ca: ?std.crypto.Certificate.Bundle = null,

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
                    // Checked before anything is loaded, so the early return
                    // has nothing to clean up.
                    if (tls_cfg.client_auth) |client_auth| {
                        if (client_auth.ca == .none) {
                            log.err("config.tls.client_auth.ca is .none, so no client certificate could ever verify", .{});
                            return error.NoCertificateAuthority;
                        }
                    }

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
                    errdefer {
                        self.tls_auth.?.deinit(self.allocator);
                        self.tls_auth = null;
                    }

                    if (tls_cfg.client_auth) |client_auth| {
                        self.tls_client_ca = client_auth.ca.load(self.allocator, self.io) catch |err| {
                            log.err("Failed to load client certificate authorities: {}", .{err});
                            return err;
                        };
                    }
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
                if (self.tls_client_ca) |*bundle| {
                    bundle.deinit(self.allocator);
                    self.tls_client_ca = null;
                }
            };

            if (self.config.max_connections) |max| {
                if (max == 0) {
                    log.err("config.max_connections is 0, so no connection could ever be served", .{});
                    return error.NoConnectionsAllowed;
                }
            }

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

            // Grows while accepting keeps failing for want of resources, and
            // is reset by the first connection that gets through.
            var backoff_ms: u64 = 0;

            while (true) {
                self.waitForConnectionSlot() catch |err| {
                    self.drainConnections();
                    return err;
                };

                const stream = server.accept(self.io) catch |err| switch (err) {
                    error.Canceled => {
                        self.drainConnections();
                        return err;
                    },
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
                        self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake) catch |sleep_err| {
                            // Acted on here, not deferred to the accept
                            // above with `recancel`. That accept keeps
                            // failing for its own reason -- the fd table is
                            // full, which is why we are in the backoff --
                            // and an operation that completes with a result
                            // of its own has the cancellation re-armed
                            // rather than reported, so the caller gets its
                            // result. Deferring therefore livelocks: the
                            // cancellation is re-armed by turns here and in
                            // the runtime, and never delivered.
                            self.drainConnections();
                            return sleep_err;
                        };
                        continue;
                    },
                    else => return err,
                };
                backoff_ms = 0;

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                group.concurrent(self.io, handleConnectionWrapper, .{ self, stream }) catch |err| {
                    log.err("Failed to spawn connection handler: {}", .{err});
                    self.releaseConnectionSlot();
                    stream.close(self.io);
                    continue;
                };
            }
        }

        /// Stops accepting and waits for the connections already in flight.
        /// Reached from every way the accept loop can learn it was canceled,
        /// so a shutdown drains whether the cancel landed on the accept or
        /// on a backoff wait.
        ///
        /// Runs under cancel protection: this is the shutdown, and a further
        /// cancel arriving mid-drain would abandon connections rather than
        /// finish with them. What bounds it is its own policy below, not
        /// whoever asked it to stop.
        ///
        /// Infallible, so that `listen` reports the cancellation that stopped
        /// it rather than a detail of how the drain went. Connections that
        /// outlast the wait are logged and left to the caller's deferred
        /// `group.cancel`, which tears them down either way.
        fn drainConnections(self: *Self) void {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);

            log.info("Graceful shutdown requested", .{});
            self.shutting_down.store(true, .release);

            // Turned into a deadline once, so the budget covers the drain as
            // a whole. A per-wait duration would restart it every time a
            // connection closed, and a steady trickle would then hold the
            // shutdown open indefinitely.
            const timeout: std.Io.Timeout = if (self.config.timeout.shutdown) |duration|
                std.Io.Timeout.toDeadline(.{ .duration = .{ .raw = duration, .clock = .awake } }, self.io)
            else
                .none;

            while (true) {
                const remaining = self.active_connections.load(.acquire);
                if (remaining == 0) return;

                if (timeout.toTimestamp(self.io)) |deadline| {
                    if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) {
                        log.warn("Shutdown timed out with {d} connection(s) still open", .{remaining});
                        return;
                    }
                }

                log.info("Waiting for {} remaining connections to close", .{remaining});
                // Wakes when a connection closes, or when the deadline
                // arrives; the loop above decides which happened. Spurious
                // wakeups just re-read the count.
                self.io.futexWaitTimeout(u32, &self.active_connections.raw, remaining, timeout) catch |err| switch (err) {
                    // Cannot happen: protection is blocked for this whole
                    // function, so no Io call here is a cancelation point.
                    error.Canceled => unreachable,
                };
            }
        }

        /// Blocks while every connection slot is taken. Not accepting is the
        /// backpressure: what arrives meanwhile waits in the kernel's accept
        /// queue, `listen.kernel_backlog` deep.
        fn waitForConnectionSlot(self: *Self) std.Io.Cancelable!void {
            const max = self.config.max_connections orelse return;
            while (true) {
                const active = self.active_connections.load(.acquire);
                if (active < max) return;
                log.debug("At the {d} connection cap; waiting for a slot", .{max});
                try self.io.futexWait(u32, &self.active_connections.raw, active);
            }
        }

        /// Wakes whoever is waiting for one: the accept loop, or the drain.
        fn releaseConnectionSlot(self: *Self) void {
            _ = self.active_connections.fetchSub(1, .acq_rel);
            self.io.futexWake(u32, &self.active_connections.raw, 1);
        }

        fn handleConnectionWrapper(self: *Self, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            if (comptime have_auto_cancel) return runConnection(self, stream, null);

            if (self.config.timeout.request == null and self.config.timeout.keepalive == null) {
                return runConnection(self, stream, null);
            }

            var watch: Watch = .{};
            var future = self.io.concurrent(runConnection, .{ self, stream, &watch }) catch |err| {
                log.warn("No task to watch the connection deadline: {}; refusing", .{err});
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
        fn runConnection(self: *Self, stream: std.Io.net.Stream, watch: ?*Watch) void {
            defer if (watch) |w| w.finish(self.io);

            handleConnection(self, stream, watch) catch |err| {
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

        pub fn handleConnection(self: *Self, stream: std.Io.net.Stream, watch: ?*Watch) !void {
            defer self.releaseConnectionSlot();

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
                        defer timer.clear(self.io);
                        if (self.config.timeout.request) |duration| {
                            timer.set(self.io, .{ .duration = .{ .raw = duration, .clock = .awake } });
                        }

                        const client_auth: ?ClientAuthRef = if (self.tls_client_ca) |*bundle| .{
                            .bundle = bundle,
                            .mode = self.config.tls.?.client_auth.?.mode,
                        } else null;

                        connection.initTls(self.allocator, self.io, stream, self.config.request.buffer_size, auth, client_auth) catch |err| {
                            // tls.zig only saw the ciphertext reader or
                            // writer fail generically, so the cause is a
                            // layer down -- and when the handshake ran out
                            // of time, that cause is the cancel.
                            const cause = switch (err) {
                                error.TransportReadFailed => connection.getReadError() orelse err,
                                error.TransportWriteFailed => connection.getWriteError() orelse err,
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

                    // Per-request arena nested on the connection arena: resetting it
                    // between keepalive requests reuses the connection's memory
                    // without touching the TLS buffers carved above.
                    var request_arena = std.heap.ArenaAllocator.init(connection.arena.allocator());
                    return self.handleRequests(&connection, &request_arena, &needs_shutdown, &timer);
                }
            }

            connection.initPlain(self.allocator, self.io, stream);
            return self.handleRequests(&connection, &connection.arena, &needs_shutdown, &timer);
        }

        /// Runs the HTTP request/keepalive loop over a connection.
        fn handleRequests(
            self: *Self,
            connection: *Connection,
            arena: *std.heap.ArenaAllocator,
            needs_shutdown: *bool,
            timer: *Timer,
        ) !void {
            var request: Request = .{
                .arena = arena.allocator(),
                .io = self.io,
                .transport = connection.transport(),
                .parser = undefined,
                .config = self.config.request,
                .remote_address = connection.stream.socket.address,
                ._timeout_context = timer,
                ._set_timeout = setRequestTimeout,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            // Allocate initial buffer from arena
            connection.reader.buffer = request.arena.alloc(u8, self.config.request.buffer_size + body_read_reserve) catch |err| {
                log.err("Failed to allocate read buffer: {}", .{err});
                return err;
            };

            while (true) {
                request_count += 1;

                // Cleared when unset, so a keepalive deadline does not carry
                // into a request meant to be unbounded.
                if (self.config.timeout.request) |duration| {
                    timer.set(self.io, .{ .duration = .{ .raw = duration, .clock = .awake } });
                } else {
                    timer.clear(self.io);
                }

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
                        return;
                    },
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
                    error.ReadFailed => return connection.getReadError() orelse error.Unexpected,
                    error.WriteFailed => return connection.getWriteError() orelse error.Unexpected,
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
                connection.reader.buffer = request.arena.alloc(u8, self.config.request.buffer_size + body_read_reserve) catch |err| {
                    log.err("Failed to allocate read buffer: {}", .{err});
                    return err;
                };
                connection.reader.seek = 0;
                connection.reader.end = 0;

                if (self.config.timeout.keepalive) |duration| {
                    timer.set(self.io, .{ .duration = .{ .raw = duration, .clock = .awake } });
                } else {
                    timer.clear(self.io);
                }

                // Fill some data here, under the keepalive timeout
                connection.reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown.* = false;
                        return;
                    },
                    error.ReadFailed => {
                        const e = connection.getReadError() orelse error.Unexpected;
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

test "Connection: the placeholders it descends past stay out of its error sets" {
    // `TransportReadFailed`/`TransportWriteFailed` mean only "the layer
    // below failed", which is what the accessors exist to look past. They
    // must not survive into what a caller can be handed, any more than the
    // `ReadFailed`/`WriteFailed` they stand in for.
    inline for (@typeInfo(Connection.ReadError).error_set.?) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, "TransportReadFailed"));
    }
    inline for (@typeInfo(Connection.WriteError).error_set.?) |e| {
        try std.testing.expect(!std.mem.eql(u8, e.name, "TransportWriteFailed"));
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

test "Watch: accepts an absolute deadline on another clock" {
    const io = std.testing.io;
    var watch: Watch = .{};
    const deadline = std.Io.Clock.Timestamp.now(io, .real).addDuration(.{
        .raw = .fromMilliseconds(50),
        .clock = .real,
    });
    watch.set(io, .{ .deadline = deadline });
    try std.testing.expectError(error.Timeout, watch.wait(io));
}

test "Watch: a deadline republished before its generation does not expire the connection" {
    const io = std.testing.io;
    var watch: Watch = .{};

    // Leave enough room for the watcher and this test task both to be
    // scheduled on a loaded runner before the first deadline arrives.
    watch.arm(io, .fromMilliseconds(500));

    var watcher = try io.concurrent(struct {
        fn go(w: *Watch, i: std.Io) (std.Io.Cancelable || std.Io.Timeout.Error)!void {
            return w.wait(i);
        }
    }.go, .{ &watch, io });
    defer watcher.cancel(io) catch {};

    // The watcher is now asleep holding the first deadline. Publish a later
    // one the way `arm` does, but stop short of the generation bump -- the
    // window between its store and its wake.
    try io.sleep(.fromMilliseconds(25), .awake);
    const later: std.Io.Timeout = .{
        .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(5_000), .clock = .awake }),
    };
    watch.mutex.lockUncancelable(io);
    watch.timeout = later;
    watch.mutex.unlock(io);

    // Well past the first deadline, and nowhere near the second.
    try io.sleep(.fromMilliseconds(600), .awake);
    watch.finish(io);

    try watcher.await(io);
}
