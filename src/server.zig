const std = @import("std");
const zio = @import("zio");
const tls = @import("tls");
const build_options = @import("build_options");

const Router = @import("router.zig").Router;
const Action = @import("router.zig").Action;
const ServerConfig = @import("config.zig").ServerConfig;
const Middleware = @import("middleware.zig").Middleware;
const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;
const h1 = @import("server/h1.zig");

pub const Connection = @import("server/connection.zig").Connection;

const log = std.log.scoped(.dusty);

/// How long the accept loop waits after failing for want of a file
/// descriptor or memory, doubling up to the cap. Short enough that a brief
/// shortage costs a little latency, capped so a sustained one settles into
/// one attempt a second rather than a spin.
const min_accept_backoff_ms = 5;
const max_accept_backoff_ms = 1000;

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

            // Grows while accepting keeps failing for want of resources, and
            // is reset by the first connection that gets through.
            var backoff_ms: u64 = 0;

            while (true) {
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
                    _ = self.active_connections.fetchSub(1, .acq_rel);
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

            // When TLS is configured, upgrade the accepted stream before
            // handing the connection to the engine. Otherwise the engine runs
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

                    return h1.Engine(Ctx).serve(self, &connection, &needs_shutdown);
                }
            }

            connection.initPlain(self.allocator, self.io, stream);
            return h1.Engine(Ctx).serve(self, &connection, &needs_shutdown);
        }
    };
}

test {
    _ = @import("server/connection.zig");
    _ = @import("server/h1.zig");
}
