const std = @import("std");
const http = @import("dusty");

// --8<-- [start:echo]
const idle_timeout: std.Io.Timeout = .{
    .duration = .{ .raw = .fromSeconds(60), .clock = .awake },
};

fn echo(req: *http.Request, res: *http.Response) !void {
    var ws = try res.upgradeWebSocket(req) orelse {
        res.status = .bad_request;
        return res.print(.text, "Expected a WebSocket upgrade\n", .{});
    };
    defer ws.deinit();

    while (true) {
        req.setTimeout(idle_timeout);
        const msg = ws.receive() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        switch (msg.type) {
            .text, .binary => try ws.send(msg.type, msg.data),
            .close => return,
            else => {},
        }
    }
}
// --8<-- [end:echo]

fn index(res: *http.Response) !void {
    try res.print(.html,
        \\<!DOCTYPE html>
        \\<html>
        \\<body>
        \\  <p>Open the browser console to see the messages.</p>
        \\  <script>
        \\    const ws = new WebSocket("ws://" + location.host + "/ws");
        \\    ws.onmessage = (e) => console.log("Received:", e.data);
        \\    ws.onopen = () => ws.send("Hello from the browser!");
        \\  </script>
        \\</body>
        \\</html>
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    server.router.get("/", index);
    server.router.get("/ws", echo);

    try server.run();
}
