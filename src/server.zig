const std = @import("std");
const zio = @import("zio");

const Router = @import("router.zig").Router;
const RequestParser = @import("parser.zig").RequestParser;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const log = std.log.scoped(.dust);

fn writeResponseHeader(writer: *std.Io.Writer, response: *Response) !void {
    // TODO maybe support 1.0 responses?
    try writer.print("HTTP/1.1 {d} {f}\r\n", .{ @intFromEnum(response.status), response.status });

    var iter = response.headers.iterator();
    while (iter.next()) |entry| {
        try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    const has_content_length = response.headers.get("Content-Length") != null;
    if (!has_content_length) {
        try writer.print("Content-Length: {d}\r\n", .{response.body.len});
    }

    // TODO add Connection header

    try writer.writeAll("\r\n");
}

fn writeResponse(writer: *std.Io.Writer, response: *Response) !void {
    try writeResponseHeader(writer, response);
    try writer.writeAll(response.body);
    try writer.flush();
}

pub fn Server(comptime Ctx: type) type {
    return struct {
        const Self = @This();

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

                var response: Response = .{
                    .arena = arena.allocator(),
                };

                if (try self.router.findHandler(&request)) |handler| {
                    handler(self.ctx, &request, &response);
                } else {
                    response.status = .not_found;
                    response.body = "404 Not Found\n";
                }

                try writeResponse(&writer.interface, &response);

                if (!parser.shouldKeepAlive() or true) {
                    break;
                }

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
