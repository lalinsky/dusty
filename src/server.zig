const std = @import("std");
const zio = @import("zio");

const Router = @import("router.zig").Router;

const log = std.log.scoped(.dust);

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
                .router = .{},
                .ctx = ctx,
                .active_connections = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.router.deinit();
        }

        pub fn listen(self: *Self, rt: *zio.Runtime, addr: zio.net.IpAddress) !void {
            const server = try addr.listen(rt, .{});
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

            // If we failed somewhere, try to shutdown the connection
            errdefer stream.shutdown(rt, .both) catch |err| {
                log.warn("Failed to shutdown client connection: {}", .{err});
            };

            var read_buffer: [4096]u8 = undefined;
            var reader = stream.reader(rt, &read_buffer);

            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(rt, &write_buffer);

            while (true) {
                // TODO actual HTTP parser

                const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };

                std.log.info("Received: {s}", .{line});
                try writer.interface.flush();

                break;
            }
        }
    };
}
