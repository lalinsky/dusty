const std = @import("std");
const http = @import("dusty");

const App = struct {
    greeting: []const u8,
};

fn index(app: *App, res: *http.Response) !void {
    try res.print(.text, "{s}, world!\n", .{app.greeting});
}

fn hello(app: *App, name: http.Param("name", []const u8), res: *http.Response) !void {
    try res.print(.text, "{s}, {s}!\n", .{ app.greeting, name.value });
}

pub fn main(init: std.process.Init) !void {
    var app: App = .{ .greeting = "Hello" };

    var server = http.Server(App).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, &app);
    defer server.deinit();

    server.router.get("/", index);
    server.router.get("/hello/:name", hello);

    try server.run();
}
