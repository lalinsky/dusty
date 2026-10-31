const std = @import("std");
const http = @import("dusty");

fn index(req: *http.Request, res: *http.Response) !void {
    try res.print(.text, "Hello over {s}\n", .{if (req.secure) "TLS" else "plain HTTP"});
}

fn runBasic(init: std.process.Init) !void {
    // --8<-- [start:config]
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8080) },
        }},
        .timeout = .{ .request = .fromSeconds(60) },
        .request = .{ .max_body_size = 10 * 1024 * 1024 },
    }, {});
    // --8<-- [end:config]
    defer server.deinit();

    server.router.get("/", index);
    try server.run();
}

fn runListeners(init: std.process.Init) !void {
    // --8<-- [start:listeners]
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{
            .{
                .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8443) },
                .tls = .{ .certificate = .{ .file = .{
                    .cert_path = "examples/certs/cert.pem",
                    .key_path = "examples/certs/key.pem",
                } } },
            },
            .{
                .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", 8080) },
            },
            .{
                .address = .{ .unix = try std.Io.net.UnixAddress.init("/tmp/app.sock") },
            },
        },
    }, {});
    // --8<-- [end:listeners]
    defer server.deinit();

    server.router.get("/", index);
    try server.run();
}

// Run with `listeners` as the argument for the TLS, plain and Unix socket
// listeners.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "listeners")) {
        try runListeners(init);
    } else {
        try runBasic(init);
    }
}
