const std = @import("std");
const http = @import("dusty");

// --8<-- [start:countdown]
fn countdown(req: *http.Request, res: *http.Response) !void {
    req.setTimeout(.none);

    var buf: [4096]u8 = undefined;
    var events = try res.startEventStream(&buf);

    var n: u32 = 10;
    while (n > 0) : (n -= 1) {
        const id = try std.fmt.allocPrint(req.arena, "{d}", .{n});
        try events.send(id, .{ .event = "tick", .id = id });
        try req.io.sleep(.fromSeconds(1), .awake);
    }
    try events.send("liftoff", .{ .event = "done" });
}
// --8<-- [end:countdown]

// --8<-- [start:writer]
fn status(req: *http.Request, res: *http.Response) !void {
    var buf: [4096]u8 = undefined;
    var events = try res.startEventStream(&buf);

    var event = try events.startSend(.{ .event = "status" });
    try event.interface.print("{{\"method\":\"{f}\",\"path\":\"{s}\"}}", .{ req.method, req.url });
    try event.end();
}
// --8<-- [end:writer]

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    server.router.get("/countdown", countdown);
    server.router.get("/status", status);

    try server.run();
}
