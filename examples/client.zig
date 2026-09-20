const std = @import("std");
const http = @import("dusty");

fn usage(argv0: []const u8) noreturn {
    std.debug.print("Usage: {s} [--timeout SECONDS|none] [--buffered] <url>\n", .{argv0});
    std.debug.print("Example: {s} --timeout 5 https://httpbin.org/delay/3\n", .{argv0});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var url: ?[]const u8 = null;
    // Null inherits the client default; `.none` lifts it.
    var timeout: ?std.Io.Timeout = null;
    var stream = true;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) usage(args[0]);
            if (std.mem.eql(u8, args[i], "none")) {
                timeout = .none;
            } else {
                const seconds = std.fmt.parseFloat(f64, args[i]) catch usage(args[0]);
                const ms: i64 = @intFromFloat(seconds * std.time.ms_per_s);
                timeout = .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
            }
        } else if (std.mem.eql(u8, arg, "--buffered")) {
            // The body is then read inside `fetch`, under the timeout.
            stream = false;
        } else if (url == null) {
            url = arg;
        } else {
            usage(args[0]);
        }
    }

    var client = http.Client.init(allocator, io, .{});
    defer client.deinit();

    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var response = client.fetch(url orelse usage(args[0]), .{
        .stream = stream,
        .timeout = timeout,
    }) catch |err| {
        std.debug.print("Request failed after {f}: {t}\n", .{ started.untilNow(io).raw, err });
        std.process.exit(2);
    };
    defer response.deinit();

    std.debug.print("Status: {any} after {f}\n", .{ response.status(), started.untilNow(io).raw });

    std.debug.print("Headers:\n", .{});
    var it = response.headers().iterator();
    while (it.next()) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.key, entry.value });
    }

    std.debug.print("\n", .{});

    var read_buf: [8192]u8 = undefined;
    var body_reader = try response.reader(&read_buf);
    var write_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &write_buf);
    const total_bytes = try body_reader.interface.streamRemaining(&out.interface);
    try out.interface.flush();
    std.debug.print("Total bytes: {d}\n", .{total_bytes});
}
