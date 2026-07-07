const std = @import("std");
const zio = @import("zio");
const http = @import("dusty");

fn handleRoot(_: *http.Request, res: *http.Response) !void {
    res.body = "Hello World!\n";
}

/// Parses `--<name>=<uint>` and returns the value, or null if `arg` doesn't
/// match the flag or the value doesn't parse.
fn uintFlag(arg: []const u8, comptime name: []const u8) ?u64 {
    const prefix = "--" ++ name ++ "=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    return std.fmt.parseUnsigned(u64, arg[prefix.len..], 10) catch null;
}

pub fn main(init: std.process.Init) !void {
    // Options (all optional):
    //   --threads=N             executor threads (default: auto = all cores)
    //   --request-timeout=SECS  max time to receive a request (default: none)
    //   --keepalive-timeout=SECS max idle time on a keepalive connection (default: none)
    var threads: usize = 0; // 0 = auto
    var request_timeout: ?std.Io.Duration = null;
    var keepalive_timeout: ?std.Io.Duration = null;
    {
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.next(); // argv0
        while (args.next()) |arg| {
            if (uintFlag(arg, "threads")) |v| {
                threads = @intCast(v);
            } else if (uintFlag(arg, "request-timeout")) |v| {
                request_timeout = .fromSeconds(@intCast(v));
            } else if (uintFlag(arg, "keepalive-timeout")) |v| {
                keepalive_timeout = .fromSeconds(@intCast(v));
            } else {
                std.log.warn("ignoring unknown argument: {s}", .{arg});
            }
        }
    }

    var rt = if (threads == 0)
        try zio.Runtime.init(init.gpa, .{ .executors = .auto })
    else
        try zio.Runtime.init(init.gpa, .{ .executors = .exact(@intCast(threads)) });
    defer rt.deinit();

    var server = http.Server(void).init(init.gpa, rt.io(), .{
        .timeout = .{
            .request = request_timeout,
            .keepalive = keepalive_timeout,
        },
    }, {});
    defer server.deinit();

    server.router.get("/", handleRoot);

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", 8080) };
    std.log.info("Starting server on http://127.0.0.1:8080 (threads={d}, request_timeout={}, keepalive_timeout={})", .{
        threads,
        request_timeout != null,
        keepalive_timeout != null,
    });
    try server.listen(addr);
}
