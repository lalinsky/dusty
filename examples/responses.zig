const std = @import("std");
const http = @import("dusty");

const App = struct {
    files: std.Io.Dir,
};

// --8<-- [start:basic]
fn createUser(res: *http.Response) !void {
    res.status = .created;
    try res.header("Location", "/users/42");
    try res.print(.json, "{{\"id\":{d}}}\n", .{42});
}
// --8<-- [end:basic]

// --8<-- [start:redirect]
fn oldPage(res: *http.Response) !void {
    res.status = .moved_permanently;
    try res.header("Location", "/new-page");
}
// --8<-- [end:redirect]

// --8<-- [start:writer]
fn listItems(res: *http.Response) !void {
    var body = res.writer();
    for (0..3) |i| {
        try body.interface.print("Item {d}\n", .{i});
    }
    try body.end();
    res.content_type = .text;
}
// --8<-- [end:writer]

// --8<-- [start:stream]
fn countdown(req: *http.Request, res: *http.Response) !void {
    res.content_type = .text;
    var buf: [1024]u8 = undefined;
    var body = try res.stream(&buf);
    var i: usize = 3;
    while (i > 0) : (i -= 1) {
        try body.interface.print("{d}...\n", .{i});
        try body.interface.flush();
        try req.io.sleep(.fromSeconds(1), .awake);
    }
    try body.interface.writeAll("Done\n");
    try body.end();
}
// --8<-- [end:stream]

// --8<-- [start:file]
fn download(app: *App, res: *http.Response) !void {
    _ = res.sendFile(app.files, "report.pdf", .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    try res.header("Content-Disposition", "attachment");
}
// --8<-- [end:file]

// --8<-- [start:compress]
fn report(res: *http.Response) !void {
    res.compress = true;
    res.content_type = .text;
    var body = res.writer();
    for (0..1000) |i| try body.interface.print("Line {d} of a long report\n", .{i});
    try body.end();
}
// --8<-- [end:compress]

// --8<-- [start:cookie]
fn setTheme(res: *http.Response) !void {
    try res.setCookie("theme", "dark", .{
        .path = "/",
        .max_age = .fromSeconds(365 * 24 * 60 * 60),
        .http_only = true,
        .same_site = .lax,
    });
    try res.print(.text, "Theme saved\n", .{});
}
// --8<-- [end:cookie]

pub fn main(init: std.process.Init) !void {
    var files = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer files.close(init.io);

    var app: App = .{ .files = files };

    var server = http.Server(App).init(init.gpa, init.io, .{
        .listeners = &.{.{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) },
        }},
    }, &app);
    defer server.deinit();

    server.router.post("/users", createUser);
    server.router.get("/old-page", oldPage);
    server.router.get("/items", listItems);
    server.router.get("/countdown", countdown);
    server.router.get("/report.pdf", download);
    server.router.get("/report", report);
    server.router.post("/theme", setTheme);

    try server.run();
}
