const std = @import("std");
const zio = @import("zio");

const Router = @import("router.zig").Router;
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
        shutdown: zio.ResetEvent,
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
                .shutdown = .init,
                .last_connection_closed = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn stop(self: *Self) void {
            log.info("Shutting down", .{});
            self.shutdown.set();
        }

        pub fn listen(self: *Self, rt: *zio.Runtime, addr: zio.net.IpAddress) !void {
            const server = try addr.listen(rt, .{ .reuse_address = true });
            defer server.close(rt);

            self.address = server.socket.address;
            self.ready.set();

            log.info("Listening on {f}", .{self.address});

            var listener = try rt.spawn(acceptLoop, .{ self, rt, server }, .{});
            defer listener.cancel(rt);

            const selected = try zio.select(rt, .{ .done = &listener, .shutdown = &self.shutdown });
            switch (selected) {
                .done => |result| {
                    result catch |err| {
                        log.err("Failed to accept connection: {}", .{err});
                    };
                },
                .shutdown => {},
            }

            var active_connections = self.active_connections.load(.acquire);
            while (active_connections > 0) {
                log.info("Waiting for {} remaining connections to close", .{active_connections});
                try self.last_connection_closed.timedWait(rt, 100 * std.time.ns_per_ms);
                active_connections = self.active_connections.load(.acquire);
            }
        }

        pub fn acceptLoop(self: *Self, rt: *zio.Runtime, server: zio.net.Server) !void {
            while (true) {
                const stream = try server.accept(rt);
                errdefer stream.close(rt);

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                errdefer _ = self.active_connections.fetchSub(1, .acq_rel);

                var handler = try rt.spawn(handleConnection, .{ self, rt, stream }, .{});
                handler.detach(rt);
            }
        }

        pub fn handleConnection(self: *Self, rt: *zio.Runtime, stream: zio.net.Stream) !void {
            // Close connection if it's already closed
            defer stream.close(rt);

            // Mark connection as inactive
            defer {
                const v = self.active_connections.fetchSub(1, .acq_rel);
                if (v == 1) {
                    self.last_connection_closed.broadcast();
                }
            }

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(rt, .both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var reader = stream.reader(rt, &.{});

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

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

                defer timeout.clear(rt);
                if (self.config.timeout.request) |timeout_ms| {
                    timeout.set(rt, timeout_ms * std.time.ns_per_ms);
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
                    if (comptime Ctx == void) {
                        handler(&request, &response) catch |err| {
                            self.handleError(&request, &response, err);
                        };
                    } else {
                        handler(self.ctx, &request, &response) catch |err| {
                            self.handleError(&request, &response, err);
                        };
                    }
                } else {
                    if (comptime Ctx != void and std.meta.hasFn(Ctx, "notFound")) {
                        self.ctx.notFound(&request, &response) catch |err| {
                            self.handleError(&request, &response, err);
                        };
                    } else {
                        defaultNotFound(&request, &response);
                    }
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
                    timeout.set(rt, timeout_ms * std.time.ns_per_ms);
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
