const std = @import("std");
const http = @import("dusty");

fn handleRoot(req: *http.Request, res: *http.Response) !void {
    res.body = if (req.secure) "Hello over TLS!\n" else "Hello over plain HTTP!\n";
}

fn handleJson(req: *http.Request, res: *http.Response) !void {
    res.status = .ok;
    try res.json(.{
        .message = "secure hello",
        .timestamp = std.Io.Timestamp.now(req.io, .real).toSeconds(),
    }, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Usage: tls_server-example [cert.pem] [key.pem]
    // Defaults to the bundled self-signed localhost test certificate (run from
    // the repo root). Test with: curl -k https://127.0.0.1:8443/ and
    // curl http://127.0.0.1:8080/
    const cert_path = if (args.len > 1) args[1] else "examples/certs/cert.pem";
    const key_path = if (args.len > 2) args[2] else "examples/certs/key.pem";

    var server = http.Server(void).init(init.gpa, io, .{}, {});
    defer server.deinit();

    server.router.get("/", handleRoot);
    server.router.get("/json", handleJson);

    // TLS is a property of the listener, so one server can serve HTTPS on
    // 8443 and plain HTTP on 8080 at the same time.
    const listeners = [_]http.Listener{
        .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8443) },
            .tls = .{ .cert_path = cert_path, .key_path = key_path },
        },
        .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        },
    };
    std.log.info("Starting TLS server on https://127.0.0.1:8443 and http://127.0.0.1:8080 (cert={s}, key={s})", .{ cert_path, key_path });
    try server.run(&listeners);
}
