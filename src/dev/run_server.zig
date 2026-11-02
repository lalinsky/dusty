//! Runs a server and restarts it whenever a new binary is installed in its
//! place, for `addRunServer` in build.zig: `run-server <exe> [args...]`.
//!
//! How the binary gets built is up to the user, `zig build --watch` or
//! running `zig build` by hand. A server that exits or crashes is started
//! again on the next build.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.run_server);

const poll_interval: std.Io.Duration = .fromMilliseconds(100);

/// What tells one build of the binary from the next. The install renames a
/// new file into place, so the inode changes with every build.
const Stamp = struct {
    inode: std.Io.File.INode,
    mtime: i96,
    size: u64,

    fn read(io: std.Io, path: []const u8) std.Io.Cancelable!?Stamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return null,
        };
        return .{ .inode = stat.inode, .mtime = stat.mtime.nanoseconds, .size = stat.size };
    }

    fn eql(a: Stamp, b: Stamp) bool {
        return a.inode == b.inode and a.mtime == b.mtime and a.size == b.size;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: {s} <exe> [args...]\n", .{args[0]});
        std.process.exit(1);
    }
    const exe_path = args[1];

    // Windows doesn't let a running executable be replaced, so the server
    // runs from a copy and the build is free to install a new one.
    const run_path = if (builtin.os.tag == .windows) blk: {
        const ext = std.fs.path.extension(exe_path);
        break :blk try std.mem.concat(arena, u8, &.{ exe_path[0 .. exe_path.len - ext.len], ".run-server", ext });
    } else exe_path;

    const argv = try arena.alloc([]const u8, args.len - 1);
    argv[0] = run_path;
    for (argv[1..], args[2..]) |*dst, src| dst.* = src;

    try init.environ_map.put("DUSTY_DEV", "1");

    var current = try Stamp.read(io, exe_path);
    if (current == null) log.info("waiting for {s} to be built", .{exe_path});
    while (true) {
        const stamp = current orelse {
            try io.sleep(poll_interval, .awake);
            current = try Stamp.read(io, exe_path);
            continue;
        };

        if (builtin.os.tag == .windows) {
            std.Io.Dir.cwd().copyFile(exe_path, std.Io.Dir.cwd(), run_path, io, .{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    log.err("copying {s} failed: {t}", .{ exe_path, err });
                    current = try waitForChange(io, exe_path, stamp);
                    continue;
                },
            };
        }

        current = try runUntilRebuilt(io, argv, init.environ_map, exe_path, stamp);
    }
}

/// Runs the server until a different binary is installed, and returns its
/// stamp. If the server stops first, waits for the next build.
fn runUntilRebuilt(
    io: std.Io,
    argv: []const []const u8,
    environ_map: *const std.process.Environ.Map,
    exe_path: []const u8,
    stamp: Stamp,
) !Stamp {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            log.err("starting {s} failed: {t}", .{ argv[0], err });
            return waitForChange(io, exe_path, stamp);
        },
    };

    // Read before the waiter can reap the child, which clears `child.id`.
    const id = child.id.?;
    var exited: std.atomic.Value(bool) = .init(false);
    var waiter = io.concurrent(waitChild, .{ io, &child, &exited }) catch |err| {
        child.kill(io);
        return err;
    };

    while (true) {
        io.sleep(poll_interval, .awake) catch |err| {
            stop(io, &waiter, id, &exited);
            return err;
        };

        if (exited.load(.acquire)) {
            const term = try waiter.await(io);
            switch (term) {
                .exited => |code| log.info("{s} exited with code {d}, restarting on the next build", .{ exe_path, code }),
                .signal => |sig| log.info("{s} was killed by signal {t}, restarting on the next build", .{ exe_path, sig }),
                .stopped, .unknown => log.info("{s} stopped, restarting on the next build", .{exe_path}),
            }
            return waitForChange(io, exe_path, stamp);
        }

        const next = try Stamp.read(io, exe_path) orelse continue;
        if (next.eql(stamp)) continue;

        stop(io, &waiter, id, &exited);
        log.info("{s} was rebuilt, restarting", .{exe_path});
        return next;
    }
}

/// Ends the child and lets the waiter reap it. Not `waiter.cancel` and
/// `Child.kill`: a canceled wait forgets the child, so `kill` would do
/// nothing.
///
/// Killed rather than asked to stop, since a graceful shutdown waits for
/// the event streams open pages hold.
fn stop(io: std.Io, waiter: anytype, id: std.process.Child.Id, exited: *const std.atomic.Value(bool)) void {
    if (!exited.load(.acquire)) switch (builtin.os.tag) {
        .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, .SUCCESS),
        else => std.posix.kill(id, .KILL) catch {},
    };
    _ = waiter.await(io) catch {};
}

fn waitChild(io: std.Io, child: *std.process.Child, exited: *std.atomic.Value(bool)) std.process.Child.WaitError!std.process.Child.Term {
    defer exited.store(true, .release);
    return child.wait(io);
}

fn waitForChange(io: std.Io, path: []const u8, stamp: Stamp) std.Io.Cancelable!Stamp {
    while (true) {
        try io.sleep(poll_interval, .awake);
        const next = try Stamp.read(io, path) orelse continue;
        if (!next.eql(stamp)) return next;
    }
}
