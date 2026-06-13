const std = @import("std");
const http = @import("dusty");

fn handleRoot(_: *http.Request, res: *http.Response) !void {
    res.body = "Hello over TLS!\n";
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
    // the repo root). Test with: curl -k https://127.0.0.1:8443/
    const cert_path = if (args.len > 1) args[1] else "examples/certs/cert.pem";
    const key_path = if (args.len > 2) args[2] else "examples/certs/key.pem";

    var server = http.Server(void).init(init.gpa, io, .{
        .tls = .{ .cert_path = cert_path, .key_path = key_path },
    }, {});
    defer server.deinit();

    server.router.get("/", handleRoot);
    server.router.get("/json", handleJson);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8443) };
    std.log.info("Starting TLS server on https://127.0.0.1:8443 (cert={s}, key={s})", .{ cert_path, key_path });
    try server.listen(addr);
}
