const std = @import("std");
const http = @import("dusty");

// --8<-- [start:basic]
fn getPage(client: *http.Client) !void {
    var response = try client.fetch("https://ziglang.org/", .{});
    defer response.deinit();

    const body = try response.body() orelse "";
    std.debug.print("{d}, {d} bytes\n", .{ @intFromEnum(response.status()), body.len });
}
// --8<-- [end:basic]

// --8<-- [start:post]
fn createUser(client: *http.Client, gpa: std.mem.Allocator) !void {
    var headers = try http.Headers.init(gpa, 4);
    defer headers.deinit(gpa);
    try headers.put("Content-Type", "application/json");
    try headers.put("Authorization", "Bearer secret");

    var response = try client.fetch("https://httpbin.org/post", .{
        .method = .post,
        .headers = &headers,
        .body = "{\"name\":\"Alice\"}",
    });
    defer response.deinit();

    if (response.status() != .ok) return error.UnexpectedStatus;
    std.debug.print("{s}\n", .{try response.body() orelse ""});
}
// --8<-- [end:post]

// --8<-- [start:query]
fn search(client: *http.Client, gpa: std.mem.Allocator, term: []const u8) !void {
    const url = try std.fmt.allocPrint(gpa, "https://httpbin.org/get?q={f}", .{
        std.fmt.alt(std.Uri.Component{ .raw = term }, .formatEscaped),
    });
    defer gpa.free(url);

    var response = try client.fetch(url, .{});
    defer response.deinit();
    std.debug.print("{s}\n", .{try response.body() orelse ""});
}
// --8<-- [end:query]

pub fn main(init: std.process.Init) !void {
    // --8<-- [start:client]
    var client = http.Client.init(init.gpa, init.io, .{});
    defer client.deinit();
    // --8<-- [end:client]

    try getPage(&client);
    try createUser(&client, init.gpa);
    try search(&client, init.gpa, "fish & chips");
}
