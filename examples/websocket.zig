const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

const AppContext = struct {
    io: *zio.Runtime,
};

fn handleWebSocket(_: *AppContext, req: *http.Request, res: *http.Response) !void {
    var ws = try res.upgradeWebSocket(req) orelse {
        res.status = .bad_request;
        res.body = "Expected WebSocket upgrade\n";
        return;
    };
    errdefer ws.close(.internal_error, "handler error") catch {};

    try ws.send(.text, "Welcome to the WebSocket echo server!");

    while (true) {
        const msg = ws.receive() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        switch (msg.type) {
            .text => {
                // Echo the message back
                std.log.info("Received: {s}", .{msg.data});
                try ws.send(.text, msg.data);
            },
            .binary => {
                std.log.info("Received binary: {d} bytes", .{msg.data.len});
                try ws.send(.binary, msg.data);
            },
            .close => {
                std.log.info("Client closed connection", .{});
                break;
            },
            else => {},
        }
    }

    try ws.close(.normal, "goodbye");
}

fn handleIndex(_: *AppContext, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "text/html");
    res.body =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>WebSocket Echo</title></head>
        \\<body>
        \\  <h1>WebSocket Echo Server</h1>
        \\  <p>Open your browser console and run:</p>
        \\  <pre>
        \\const ws = new WebSocket("ws://localhost:8080/ws");
        \\ws.onmessage = (e) => console.log("Received:", e.data);
        \\ws.onopen = () => ws.send("Hello!");
        \\  </pre>
        \\  <script>
        \\    const ws = new WebSocket("ws://localhost:8080/ws");
        \\    ws.onmessage = (e) => console.log("Received:", e.data);
        \\    ws.onopen = () => {
        \\      console.log("Connected!");
        \\      ws.send("Hello from browser!");
        \\    };
        \\    ws.onclose = () => console.log("Disconnected");
        \\  </script>
        \\</body>
        \\</html>
    ;
}

pub fn runServer(allocator: std.mem.Allocator, io: *zio.Runtime) !void {
    var ctx: AppContext = .{ .io = io };

    var server = http.Server(AppContext).init(allocator, .{}, &ctx);
    defer server.deinit();

    server.router.get("/", handleIndex);
    server.router.get("/ws", handleWebSocket);

    const addr = try zio.net.IpAddress.parseIp("127.0.0.1", 8080);

    std.log.info("WebSocket echo server running at http://127.0.0.1:8080", .{});
    try server.listen(addr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = try zio.Runtime.init(allocator, .{});
    defer io.deinit();

    var task = try zio.spawn(runServer, .{ allocator, io });
    try task.join();
}
