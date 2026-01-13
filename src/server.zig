const std = @import("std");
const zio = @import("zio");

const Router = @import("router.zig").Router;
const Action = @import("router.zig").Action;
const RequestParser = @import("parser.zig").RequestParser;
const Request = @import("request.zig").Request;
const parseHeaders = @import("request.zig").parseHeaders;
const Response = @import("response.zig").Response;
const ServerConfig = @import("config.zig").ServerConfig;

const log = std.log.scoped(.dusty);

fn defaultUncaughtError(req: *Request, res: *Response, err: anyerror) void {
    _ = req;
    log.err("Handler failed: {}", .{err});
    res.status = .internal_server_error;
    res.body = "500 Internal Server Error\n";
}

fn defaultNotFound(req: *Request, res: *Response) void {
    log.info("No handler found for {s}", .{req.url});
    res.status = .not_found;
    res.body = "404 Not Found\n";
}

pub fn Server(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        fn handleDispatch(self: *Self, action: *const Action(Ctx), req: *Request, res: *Response) void {
            if (comptime Ctx != void and std.meta.hasFn(Ctx, "dispatch")) {
                self.ctx.dispatch(action, req, res) catch |err| {
                    self.handleError(req, res, err);
                };
            } else {
                if (comptime Ctx == void) {
                    action(req, res) catch |err| {
                        self.handleError(req, res, err);
                    };
                } else {
                    action(self.ctx, req, res) catch |err| {
                        self.handleError(req, res, err);
                    };
                }
            }
        }

        fn handleNotFound(self: *Self, req: *Request, res: *Response) void {
            if (comptime Ctx != void and std.meta.hasFn(Ctx, "notFound")) {
                self.ctx.notFound(req, res) catch |err| {
                    self.handleError(req, res, err);
                };
            } else {
                defaultNotFound(req, res);
            }
        }

        fn handleError(self: *Self, req: *Request, res: *Response, err: anyerror) void {
            if (comptime Ctx != void and std.meta.hasFn(Ctx, "uncaughtError")) {
                self.ctx.uncaughtError(req, res, err);
            } else {
                defaultUncaughtError(req, res, err);
            }
        }

        allocator: std.mem.Allocator,
        router: Router(Ctx),
        ctx: if (Ctx == void) void else *Ctx,
        config: ServerConfig,
        active_connections: std.atomic.Value(usize),
        address: zio.net.Address,
        ready: zio.ResetEvent,
        last_connection_closed: zio.Notify,

        pub fn init(allocator: std.mem.Allocator, config: ServerConfig, ctx: if (Ctx == void) void else *Ctx) Self {
            return .{
                .allocator = allocator,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .active_connections = std.atomic.Value(usize).init(0),
                .address = undefined,
                .ready = .init,
                .last_connection_closed = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn listen(self: *Self, io: *zio.Runtime, addr: zio.net.IpAddress) !void {
            const server = try addr.listen(io, .{ .reuse_address = true });
            defer server.close(io);

            self.address = server.socket.address;
            self.ready.set();

            log.info("Listening on {f}", .{self.address});

            var group: zio.Group = .init;
            defer group.cancel(io);

            while (true) {
                const stream = server.accept(io) catch |err| {
                    if (err == error.Canceled) {
                        log.info("Graceful shutdown requested", .{});
                        while (true) { // TODO: add graceful shutdown timeout
                            const remaining = self.active_connections.load(.acquire);
                            if (remaining == 0) break;
                            log.info("Waiting for {} remaining connections to close", .{remaining});
                            try self.last_connection_closed.timedWait(io, 100 * std.time.ns_per_ms);
                        }
                        return err;
                    }
                    return err;
                };

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                group.spawn(io, handleConnection, .{ self, io, stream }) catch |err| {
                    log.err("Failed to accept connection: {}", .{err});
                    _ = self.active_connections.fetchSub(1, .acq_rel);
                    stream.close(io);
                };
            }
        }

        pub fn handleConnection(self: *Self, io: *zio.Runtime, stream: zio.net.Stream) !void {
            defer {
                const v = self.active_connections.fetchSub(1, .acq_rel);
                if (v == 1) {
                    self.last_connection_closed.broadcast();
                }
            }

            defer stream.close(io);

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(io, .both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var reader = stream.reader(io, &.{});

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(io, &write_buffer);

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

            var timeout = zio.Timeout.init;

            // Allocate initial buffer from arena
            reader.interface.buffer = request.arena.alloc(u8, self.config.request.buffer_size + 1024) catch |err| {
                log.err("Failed to allocate read buffer: {}", .{err});
                return err;
            };

            while (true) {
                request_count += 1;

                defer timeout.clear(io);
                if (self.config.timeout.request) |timeout_ms| {
                    timeout.set(io, timeout_ms * std.time.ns_per_ms);
                }

                // TODO: handle error.Canceled caused by timeout and return 504

                parseHeaders(&reader.interface, &parser) catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown = false;
                        return;
                    },
                    else => return err,
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

                if (try self.router.findHandler(&request)) |handler| {
                    self.handleDispatch(handler, &request, &response);
                } else {
                    self.handleNotFound(&request, &response);
                }

                if (!parser.isBodyComplete()) {
                    // TODO maybe we should drain the body here?
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
                    timeout.set(io, timeout_ms * std.time.ns_per_ms);
                }

                // Fill some data here, while the the keepalive timeout is active
                reader.interface.fillMore() catch |err| switch (err) {
                    error.EndOfStream => {
                        needs_shutdown = false;
                        return;
                    },
                    else => {
                        // TODO: handle error.Canceled caused by timeout and return cleanly
                        return err;
                    },
                };
            }
        }
    };
}

test {
    _ = RequestParser;
}
