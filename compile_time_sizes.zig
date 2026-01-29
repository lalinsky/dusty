// This file uses @compileError to display size information at compile time
// Run with: zig build-exe compile_time_sizes.zig
// The "error" output will contain the size information

const Current = struct {
    ref_count: usize,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const Opt1 = struct {
    ref_count: u8,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const Opt2 = struct {
    ref_count: usize,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const OptBoth = struct {
    ref_count: u8,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const std = @import("std");

pub fn main() void {
    // Create formatted output at compile time
    const msg = std.fmt.comptimePrint(
        \\
        \\=== Awaitable Size Analysis (64-bit) ===
        \\Current layout:          {} bytes
        \\Opt #1 (u8 ref_count):   {} bytes (saves {})
        \\Opt #2 (optional ptr):   {} bytes (saves {})
        \\Both optimizations:      {} bytes (saves {})
        \\
        \\Savings percentage with both: {}%
        \\
    , .{
        @sizeOf(Current),
        @sizeOf(Opt1),
        @as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(Opt1)),
        @sizeOf(Opt2),
        @as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(Opt2)),
        @sizeOf(OptBoth),
        @as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(OptBoth)),
        @divFloor((@as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(OptBoth))) * 100, @as(i32, @sizeOf(Current))),
    });

    @compileError(msg);
}
