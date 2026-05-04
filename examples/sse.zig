const std = @import("std");
const http = @import("dusty");

const AppContext = struct {
    counter: std.atomic.Value(u64),
};

fn handleEvents(ctx: *AppContext, req: *http.Request, res: *http.Response) !void {
    var stream = try res.startEventStream();

    try stream.send("connected", .{});

    var last_seen: u64 = 0;
    while (true) {
        const current = ctx.counter.load(.acquire);
        if (current != last_seen) {
            last_seen = current;
            var buf: [64]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "tick {d}", .{current});
            try stream.send(msg, .{ .event = "tick" });
        }
        try req.io.sleep(.fromMilliseconds(100), .real);
    }
}

pub fn runServer(allocator: std.mem.Allocator, io: std.Io) !void {
    var ctx: AppContext = .{ .counter = std.atomic.Value(u64).init(0) };

    var server = http.Server(AppContext).init(allocator, io, .{}, &ctx);
    defer server.deinit();

    server.router.get("/events", handleEvents);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };

    std.log.info("SSE server running at http://127.0.0.1:8080", .{});
    std.log.info("Try: curl http://127.0.0.1:8080/events", .{});

    // Run ticker in background
    var ticker_future = try io.concurrent(struct {
        fn run(counter: *std.atomic.Value(u64), _io: std.Io) !void {
            while (true) {
                try _io.sleep(.fromMilliseconds(1000), .real);
                _ = counter.fetchAdd(1, .release);
            }
        }
    }.run, .{ &ctx.counter, io });
    defer ticker_future.cancel(io) catch {};

    try server.listen(addr);
}

pub fn main(init: std.process.Init) !void {
    try runServer(init.gpa, init.io);
}
