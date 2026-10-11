//! The kernel's ceiling on a listen backlog, used as the default backlog.
//!
//! This mirrors Go's `maxListenerBacklog`: on Linux the ceiling is
//! `net.core.somaxconn`, read from /proc/sys/net/core/somaxconn, and
//! elsewhere, or when that file cannot be read, it is the platform's
//! `SOMAXCONN`. The kernel silently caps any larger backlog to this anyway,
//! so asking for it means asking for the most the system allows.

const std = @import("std");
const builtin = @import("builtin");

/// What `listen` gets when the file is missing or says nothing usable: the
/// platform's `SOMAXCONN`, as Go's `syscall.SOMAXCONN` has it. Spelled out
/// rather than taken from `std.c`, whose Windows value does not compile.
const fallback: u31 = switch (builtin.os.tag) {
    // winsock2.h; the provider picks "a reasonable maximum" for it.
    .windows => 0x7fffffff,
    else => 128,
};

/// The largest backlog the kernel will honor. At least 1.
pub fn somaxconn(io: std.Io) std.Io.Cancelable!u31 {
    if (builtin.os.tag != .linux) return fallback;
    var buf: [32]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, "/proc/sys/net/core/somaxconn", &buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return fallback,
    };
    return parse(content) orelse fallback;
}

/// The value in the file, or null when it is not a positive number.
fn parse(content: []const u8) ?u31 {
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, content, " \t\n"), 10) catch return null;
    if (n == 0) return null;
    return @intCast(@min(n, std.math.maxInt(u31)));
}

test "parse: the number in the file" {
    try std.testing.expectEqual(@as(?u31, 4096), parse("4096\n"));
    try std.testing.expectEqual(@as(?u31, 128), parse("128"));
}

test "parse: zero and garbage are not a backlog" {
    try std.testing.expectEqual(@as(?u31, null), parse("0\n"));
    try std.testing.expectEqual(@as(?u31, null), parse(""));
    try std.testing.expectEqual(@as(?u31, null), parse("-1\n"));
    try std.testing.expectEqual(@as(?u31, null), parse("lots\n"));
}

test "parse: capped to what listen takes" {
    try std.testing.expectEqual(@as(?u31, std.math.maxInt(u31)), parse("4294967295\n"));
}

test "somaxconn: positive" {
    try std.testing.expect(try somaxconn(std.testing.io) > 0);
}
