const std = @import("std");
const http = @import("dusty");

pub fn main(init: std.process.Init) !void {
    var server = http.Server(void).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, {});
    defer server.deinit();

    // --8<-- [start:static]
    var dir = try std.Io.Dir.cwd().openDir(init.io, "examples/static", .{});
    defer dir.close(init.io);

    server.router.static("/static", dir, .{
        .cache_control = "public, max-age=3600",
    });
    // --8<-- [end:static]

    // --8<-- [start:embedded]
    server.router.embedded("/robots.txt", "User-agent: *\nDisallow: /admin/\n", .{});
    // --8<-- [end:embedded]

    try server.run();
}
