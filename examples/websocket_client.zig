const std = @import("std");
const http = @import("dusty");

// Talks to the server in websocket.zig.
pub fn main(init: std.process.Init) !void {
    var client = http.Client.init(init.gpa, init.io, .{});
    defer client.deinit();

    // --8<-- [start:connect]
    var ws = try client.connectWebSocket("ws://127.0.0.1:8080/ws", .{});
    defer ws.deinit();

    try ws.send(.text, "hello");

    const msg = try ws.receive();
    std.debug.print("{s}\n", .{msg.data});

    try ws.close(.normal, "bye");
    // --8<-- [end:connect]
}
