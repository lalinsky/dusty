const std = @import("std");
const zio = @import("zio");

const Router = @import("router.zig").Router;
const RequestParser = @import("parser.zig").RequestParser;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const log = std.log.scoped(.dust);

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

pub const Config = struct {
    timeout: Timeout = .{},

    pub const Timeout = struct {
        /// Maximum time (ms) to receive a complete request
        request: ?u64 = null,
        /// Maximum time (ms) to keep idle connections open
        keepalive: ?u64 = null,
        /// Maximum number of requests per keepalive connection
        request_count: ?usize = null,
    };
};

pub fn Server(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        fn handleError(self: *Self, req: *Request, res: *Response, err: anyerror) void {
            if (comptime std.meta.hasFn(Ctx, "uncaughtError")) {
                self.ctx.uncaughtError(req, res, err);
            } else {
                defaultUncaughtError(req, res, err);
            }
        }

        allocator: std.mem.Allocator,
        router: Router(Ctx),
        ctx: *Ctx,
        config: Config,
        active_connections: std.atomic.Value(usize),
        address: zio.net.Address,
        ready: zio.ResetEvent,

        pub fn init(allocator: std.mem.Allocator, config: Config, ctx: *Ctx) Self {
            return .{
                .allocator = allocator,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .active_connections = std.atomic.Value(usize).init(0),
                .address = undefined,
                .ready = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn listen(self: *Self, rt: *zio.Runtime, addr: zio.net.IpAddress) !void {
            const server = try addr.listen(rt, .{ .reuse_address = true });
            defer server.close(rt);

            log.info("Listening on {f}", .{server.socket.address});
            self.address = server.socket.address;
            self.ready.set();

            while (true) {
                const stream = try server.accept(rt);
                errdefer stream.close(rt);

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                errdefer _ = self.active_connections.fetchSub(1, .acq_rel);

                var task = try rt.spawn(handleConnection, .{ self, rt, stream }, .{});
                task.detach(rt);
            }
        }

        pub fn handleConnection(self: *Self, rt: *zio.Runtime, stream: zio.net.Stream) !void {
            // Close connection if it's already closed
            defer stream.close(rt);

            // Mark connection as inactive
            defer _ = self.active_connections.fetchSub(1, .acq_rel);

            var needs_shutdown = true;
            defer if (needs_shutdown) stream.shutdown(rt, .both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var request: Request = .{
                .arena = arena.allocator(),
                .conn = &reader.interface,
                .parser = undefined,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            var timeout = zio.Timeout.init;

            while (true) {
                request_count += 1;

                defer timeout.clear(rt);
                if (self.config.timeout.request) |timeout_ms| {
                    timeout.set(rt, timeout_ms * std.time.ns_per_ms);
                }

                // TODO: handle error.Canceled caused by timeout and return 504

                var parsed_len: usize = 0;
                while (!parser.state.headers_complete) {
                    const buffered = reader.interface.buffered();
                    const unparsed = buffered[parsed_len..];
                    if (unparsed.len > 0) {
                        parser.feed(unparsed) catch |err| switch (err) {
                            error.Paused => {
                                // Parser paused after headers, track consumed bytes
                                const consumed = parser.getConsumedBytes(unparsed.ptr);
                                parsed_len += consumed;
                                continue;
                            },
                            else => return err,
                        };
                        // If we get here, parsing is still going (no pause yet)
                        parsed_len += unparsed.len;
                        continue;
                    }

                    reader.interface.fillMore() catch |err| switch (err) {
                        error.EndOfStream => {
                            needs_shutdown = false;
                            if (parsed_len == 0) {
                                return;
                            } else {
                                return error.IncompleteRequest;
                            }
                        },
                        else => return err,
                    };
                }

                // Toss what we hav read from the buffer so far,
                // body reading will use a different strategy
                reader.interface.toss(parsed_len);

                // Resume parser after headers pause
                parser.resumeParsing();

                // Feed empty buffer to advance parser state machine
                // This allows llhttp__after_headers_complete to run, which will
                // call on_message_complete for requests without bodies (e.g. GET)
                const empty: []const u8 = &.{};
                parser.feed(empty) catch |err| switch (err) {
                    error.Paused => {}, // Expected if message is complete
                    else => return err,
                };

                std.log.info("Received: {f} {s}", .{ request.method, request.url });

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
                    handler(self.ctx, &request, &response) catch |err| {
                        self.handleError(&request, &response, err);
                    };
                } else {
                    if (comptime std.meta.hasFn(Ctx, "notFound")) {
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
                _ = arena.reset(.retain_capacity);

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
