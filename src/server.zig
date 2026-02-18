const std = @import("std");
const zio = @import("zio");

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

pub fn Server(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        router: Router(Ctx),
        ctx: if (Ctx == void) void else *Ctx,
        config: ServerConfig,
        shutting_down: std.atomic.Value(bool),
        active_connections: std.atomic.Value(usize),
        address: zio.net.Address,
        ready: zio.ResetEvent,
        last_connection_closed: zio.Notify,
        _middleware_registry: std.SinglyLinkedList,

        pub fn init(allocator: std.mem.Allocator, config: ServerConfig, ctx: if (Ctx == void) void else *Ctx) Self {
            return .{
                .allocator = allocator,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .shutting_down = std.atomic.Value(bool).init(false),
                .active_connections = std.atomic.Value(usize).init(0),
                .address = undefined,
                .ready = .init,
                .last_connection_closed = .init,
                ._middleware_registry = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            // Call deinit on all registered middlewares
            var it = self._middleware_registry.first;
            while (it) |node| {
                it = node.next;
                const mw: *Middleware(Ctx) = @fieldParentPtr("node", node);
                mw.deinit();
            }
            self.router.deinit();
        }

        /// Creates a middleware instance managed by the server.
        /// The middleware is allocated on the router's arena and will be freed when the server is deinit'd.
        /// Supports middlewares with init(Config) or init(Config, MiddlewareConfig) signatures.
        pub fn middleware(self: *Self, comptime M: type, config: M.Config) !*Middleware(Ctx) {
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

            const mw = try arena.create(Middleware(Ctx));
            mw.* = Middleware(Ctx).init(m);

            // Register for cleanup on deinit
            self._middleware_registry.prepend(&mw.node);

            return mw;
        }

        pub fn listen(self: *Self, addr: zio.net.IpAddress) !void {
            const server = try addr.listen(self.config.listen);
            defer server.close();

            self.address = server.socket.address;
            self.ready.set();

            log.info("Listening on {f}", .{self.address});

            var group: zio.Group = .init;
            defer {
                self.shutting_down.store(true, .release);
                group.cancel();
            }

            while (true) {
                const stream = server.accept() catch |err| {
                    if (err == error.Canceled) {
                        log.info("Graceful shutdown requested", .{});
                        self.shutting_down.store(true, .release);
                        while (true) { // TODO: add graceful shutdown timeout
                            const remaining = self.active_connections.load(.acquire);
                            if (remaining == 0) break;
                            log.info("Waiting for {} remaining connections to close", .{remaining});
                            try self.last_connection_closed.timedWait(.fromMilliseconds(100));
                        }
                        return err;
                    }
                    return err;
                };

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                group.spawn(handleConnection, .{ self, stream }) catch |err| {
                    log.err("Failed to accept connection: {}", .{err});
                    _ = self.active_connections.fetchSub(1, .acq_rel);
                    stream.close();
                };
            }
        }

        pub fn handleConnection(self: *Self, stream: zio.net.Stream) !void {
            defer {
                const v = self.active_connections.fetchSub(1, .acq_rel);
                if (v == 1) {
                    self.last_connection_closed.broadcast();
                }
            }

            defer stream.close();

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(.both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var reader = stream.reader(&.{});

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(&write_buffer);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var request: Request = .{
                .arena = arena.allocator(),
                .conn = &reader.interface,
                .parser = undefined,
                .config = self.config.request,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            var timeout = zio.AutoCancel.init;

            // Allocate initial buffer from arena
            reader.interface.buffer = request.arena.alloc(u8, self.config.request.buffer_size + 1024) catch |err| {
                log.err("Failed to allocate read buffer: {}", .{err});
                return err;
            };

            while (true) {
                request_count += 1;

                defer timeout.clear();
                if (self.config.timeout.request) |timeout_ms| {
                    timeout.set(.fromMilliseconds(timeout_ms));
                }

                // TODO: handle error.Canceled caused by timeout and return 504

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

                var executor = Executor(Ctx){
                    .req = &request,
                    .res = &response,
                    .ctx = self.ctx,
                    .action = try self.router.findHandler(&request),
                    .middlewares = self.router.middlewares,
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

                // Activate keepalive timeout
                if (self.config.timeout.keepalive) |timeout_ms| {
                    timeout.set(.fromMilliseconds(timeout_ms));
                }

                // Fill some data here, while the the keepalive timeout is active
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
