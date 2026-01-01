const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const BroadcastChannel = zio.BroadcastChannel;

const AppContext = struct {
    rt: *zio.Runtime,
    channel: *BroadcastChannel([]const u8),
};

fn handleEvents(ctx: *AppContext, _: *http.Request, res: *http.Response) !void {
    var stream = try res.startEventStream();

    var consumer: BroadcastChannel([]const u8).Consumer = .{};
    ctx.channel.subscribe(&consumer);
    defer ctx.channel.unsubscribe(&consumer);

    try stream.send("connected", .{});

    while (true) {
        const msg = ctx.channel.receive(ctx.rt, &consumer) catch |err| switch (err) {
            error.Closed => break,
            error.Lagged => continue,
            else => return err,
        };
        try stream.send(msg, .{ .event = "tick" });
    }
}

fn ticker(rt: *zio.Runtime, channel: *BroadcastChannel([]const u8)) !void {
    var count: u32 = 0;
    while (true) {
        try rt.sleep(1000);
        count += 1;

        var buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "tick {d}", .{count});

        channel.send(msg) catch |err| switch (err) {
            error.Closed => break,
        };
    }
}

pub fn runServer(allocator: std.mem.Allocator, rt: *zio.Runtime) !void {
    var channel_buffer: [16][]const u8 = undefined;
    var channel = BroadcastChannel([]const u8).init(&channel_buffer);

    var ctx: AppContext = .{ .rt = rt, .channel = &channel };

    var server = http.Server(AppContext).init(allocator, .{}, &ctx);
    defer server.deinit();

    server.router.get("/events", handleEvents);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);

    var ticker_task = try rt.spawn(ticker, .{ rt, &channel }, .{});
    defer ticker_task.cancel(rt);

    try server.listen(rt, addr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var task = try rt.spawn(runServer, .{ allocator, rt }, .{});
    try task.join(rt);
}
