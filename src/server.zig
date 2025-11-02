const std = @import("std");
const zio = @import("zio");

const Router = @import("router.zig").Router;
const RequestParser = @import("parser.zig").RequestParser;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const log = std.log.scoped(.dust);

fn defaultUncaughtError(req: *const Request, res: *Response, err: anyerror) void {
    _ = req;
    log.err("Handler failed: {}", .{err});
    res.status = .internal_server_error;
    res.body = "500 Internal Server Error\n";
}

fn defaultNotFound(req: *const Request, res: *Response) void {
    log.info("No handler found for {s}", .{req.url});
    res.status = .not_found;
    res.body = "404 Not Found\n";
}

pub fn Server(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        fn handleError(self: *Self, req: *const Request, res: *Response, err: anyerror) void {
            if (comptime std.meta.hasFn(Ctx, "uncaughtError")) {
                self.ctx.uncaughtError(req, res, err);
            } else {
                defaultUncaughtError(req, res, err);
            }
        }

        allocator: std.mem.Allocator,
        router: Router(Ctx),
        ctx: *Ctx,
        active_connections: std.atomic.Value(usize),

        pub fn init(allocator: std.mem.Allocator, ctx: *Ctx) Self {
            return .{
                .allocator = allocator,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .active_connections = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn listen(self: *Self, rt: *zio.Runtime, addr: zio.net.IpAddress) !void {
            const server = try addr.listen(rt, .{ .reuse_address = true });
            defer server.close(rt);

            log.info("Listening on {f}", .{server.socket.address});

            while (true) {
                const stream = try server.accept(rt);
                errdefer stream.close(rt);

                _ = self.active_connections.fetchAdd(1, .acq_rel);
                errdefer _ = self.active_connections.fetchSub(1, .acq_rel);

                var task = try rt.spawn(handleConnection, .{ self, rt, stream }, .{});
                task.detach(rt);
            }
        }

        fn handleConnection(self: *Self, rt: *zio.Runtime, stream: zio.net.Stream) !void {
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
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            while (true) {
                var parsed_len: usize = 0;
                while (!parser.state.headers_complete) {
                    const buffered = reader.interface.buffered();
                    const unparsed = buffered[parsed_len..];
                    if (unparsed.len > 0) {
                        try parser.feed(unparsed);
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

                std.log.info("Received: {f} {s}", .{ request.method, request.url });

                var response = Response.init(arena.allocator(), &writer.interface);
                if (!parser.shouldKeepAlive()) {
                    response.keepalive = false;
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

                try response.write();

                if (!response.keepalive) {
                    break;
                }

                reader.interface.toss(parsed_len);
                parser.reset();
                request.reset();
                _ = arena.reset(.retain_capacity);

                // TODO we need to make sure we drain previous request body
            }
        }
    };
}

test {
    _ = RequestParser;
}
