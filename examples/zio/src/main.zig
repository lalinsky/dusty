const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

fn handleRoot(_: *http.Request, res: *http.Response) !void {
    res.body = "Hello World!\n";
}

pub fn main(init: std.process.Init) !void {
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();

    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .timeout = .{
            .request = .fromSeconds(30),
            .keepalive = .fromSeconds(5),
        },
    }, {});
    defer server.deinit();

    server.router.get("/", handleRoot);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };
    std.log.info("Starting server on http://127.0.0.1:8080", .{});
    try server.listen(addr);
}
