const std = @import("std");

const Router = @import("router.zig").Router;
const Action = @import("router.zig").Action;
const RequestParser = @import("parser.zig").RequestParser;
const Request = @import("request.zig").Request;
const parseHeaders = @import("request.zig").parseHeaders;
const Response = @import("response.zig").Response;
const ServerConfig = @import("config.zig").ServerConfig;
const Executor = @import("middleware.zig").Executor;
const Middleware = @import("middleware.zig").Middleware;
const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;

const log = std.log.scoped(.dusty);

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
        active_connections: std.atomic.Value(usize),
        address: Address,
        ready: std.Io.Event,
        last_connection_closed: std.Io.Event,
        _middleware_registry: std.SinglyLinkedList,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ServerConfig, ctx: if (Ctx == void) void else *Ctx) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .shutting_down = std.atomic.Value(bool).init(false),
                .active_connections = std.atomic.Value(usize).init(0),
                .address = undefined,
                .ready = .unset,
                .last_connection_closed = .unset,
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
                            self.last_connection_closed.waitTimeout(self.io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(100), .clock = .awake } }) catch {};
                        }
                        return err;
                    }
                    return err;
                };

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                group.async(self.io, handleConnectionWrapper, .{ self, stream });
            }
        }

        fn handleConnectionWrapper(self: *Self, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            handleConnection(self, stream) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.err("Connection error: {}", .{err});
            };
        }

        pub fn handleConnection(self: *Self, stream: std.Io.net.Stream) !void {
            defer {
                const v = self.active_connections.fetchSub(1, .acq_rel);
                if (v == 1) {
                    self.last_connection_closed.set(self.io);
                }
            }

            defer stream.close(self.io);

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(self.io, .both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var reader = stream.reader(self.io, &.{});

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(self.io, &write_buffer);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var request: Request = .{
                .arena = arena.allocator(),
                .io = self.io,
                .conn = &reader.interface,
                .parser = undefined,
                .config = self.config.request,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            // Allocate initial buffer from arena
            reader.interface.buffer = request.arena.alloc(u8, self.config.request.buffer_size + 1024) catch |err| {
                log.err("Failed to allocate read buffer: {}", .{err});
                return err;
            };

            while (true) {
                request_count += 1;

                // TODO: implement request timeout (was zio.AutoCancel)

                parseHeaders(&reader.interface, &parser) catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown = false;
                        return;
                    },
                    error.ReadFailed => return reader.err orelse error.ReadFailed,
                    else => |e| return e,
                };

                log.debug("Received: {f} {s}", .{ request.method, request.url });

                var response = Response.init(arena.allocator(), &writer.interface);
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
                    error.ReadFailed => return reader.err orelse error.ReadFailed,
                    error.WriteFailed => return writer.err orelse error.WriteFailed,
                    else => |e| return e,
                };

                if (!parser.isBodyComplete()) {
                    // TODO maybe we should drain the body here?
                    response.keepalive = false;
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
                if (reader.interface.end > reader.interface.seek) {
                    break;
                }

                _ = arena.reset(.retain_capacity);

                // Allocate fresh buffer for keepalive wait (previous buffer was freed by arena reset)
                reader.interface.buffer = request.arena.alloc(u8, self.config.request.buffer_size + 1024) catch |err| {
                    log.err("Failed to allocate read buffer: {}", .{err});
                    return err;
                };
                reader.interface.seek = 0;
                reader.interface.end = 0;

                // TODO: implement keepalive timeout (was zio.AutoCancel)
                // Fill some data here
                reader.interface.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown = false;
                        return;
                    },
                    error.ReadFailed => return reader.err orelse error.ReadFailed,
                };
            }
        }
    };
}

test {
    _ = RequestParser;
}
