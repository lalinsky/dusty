const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const BroadcastChannel = zio.BroadcastChannel;

const AppContext = struct {
    channel: *BroadcastChannel(u64),
};

fn handleEvents(ctx: *AppContext, _: *http.Request, res: *http.Response) !void {
    var stream = try res.startEventStream();

    var consumer: BroadcastChannel(u64).Consumer = .{};
    ctx.channel.subscribe(&consumer);
    defer ctx.channel.unsubscribe(&consumer);

    try stream.send("connected", .{});

    var buf: [64]u8 = undefined;
    while (true) {
        const count = ctx.channel.receive(&consumer) catch |err| switch (err) {
            error.Closed => break,
            error.Lagged => continue,
            else => return err,
        };
        const msg = try std.fmt.bufPrint(&buf, "tick {d}", .{count});
        try stream.send(msg, .{ .event = "tick" });
    }
}

fn ticker(channel: *BroadcastChannel(u64)) !void {
    var count: u64 = 0;
    while (true) {
        try zio.sleep(.fromMilliseconds(1000));
        count += 1;

        channel.send(count) catch |err| switch (err) {
            error.Closed => break,
        };
    }
}

pub fn runServer(allocator: std.mem.Allocator, io: std.Io) !void {
    var channel_buffer: [16]u64 = undefined;
    var channel = BroadcastChannel(u64).init(&channel_buffer);

    var ctx: AppContext = .{ .channel = &channel };

    var server = http.Server(AppContext).init(allocator, io, .{}, &ctx);
    defer server.deinit();

    server.router.get("/events", handleEvents);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);

    var ticker_task = try zio.spawn(ticker, .{&channel});
    defer ticker_task.cancel();

    try server.listen(addr);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    try runServer(allocator, rt.io());
}
