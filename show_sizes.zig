const std = @import("std");

// Current layout
const Current = struct {
    ref_count: usize,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

// Optimization 1
const Opt1 = struct {
    ref_count: u8,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

// Optimization 2
const Opt2 = struct {
    ref_count: usize,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

// Both
const OptBoth = struct {
    ref_count: u8,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

// 32-bit simulations
const Current32 = struct {
    ref_count: u32,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const Opt1_32 = struct {
    ref_count: u8,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const Opt2_32 = struct {
    ref_count: u32,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const OptBoth32 = struct {
    ref_count: u8,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

pub fn main() void {
    const stdout = std.io.getStdOut().writer();

    stdout.print("=== Awaitable Size Analysis ===\n\n", .{}) catch unreachable;

    stdout.print("64-bit Platform (usize=8, pointer=8):\n", .{}) catch unreachable;
    stdout.print("  Current:         {} bytes\n", .{@sizeOf(Current)}) catch unreachable;
    stdout.print("  Opt1 (u8 ref):   {} bytes (saves {})\n", .{
        @sizeOf(Opt1),
        @as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(Opt1))
    }) catch unreachable;
    stdout.print("  Opt2 (opt ptr):  {} bytes (saves {})\n", .{
        @sizeOf(Opt2),
        @as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(Opt2))
    }) catch unreachable;
    stdout.print("  Both:            {} bytes (saves {})\n\n", .{
        @sizeOf(OptBoth),
        @as(i32, @sizeOf(Current)) - @as(i32, @sizeOf(OptBoth))
    }) catch unreachable;

    stdout.print("32-bit Simulation (u32=4, pointer=4):\n", .{}) catch unreachable;
    stdout.print("  Current:         {} bytes\n", .{@sizeOf(Current32)}) catch unreachable;
    stdout.print("  Opt1 (u8 ref):   {} bytes (saves {})\n", .{
        @sizeOf(Opt1_32),
        @as(i32, @sizeOf(Current32)) - @as(i32, @sizeOf(Opt1_32))
    }) catch unreachable;
    stdout.print("  Opt2 (opt ptr):  {} bytes (saves {})\n", .{
        @sizeOf(Opt2_32),
        @as(i32, @sizeOf(Current32)) - @as(i32, @sizeOf(Opt2_32))
    }) catch unreachable;
    stdout.print("  Both:            {} bytes (saves {})\n\n", .{
        @sizeOf(OptBoth32),
        @as(i32, @sizeOf(Current32)) - @as(i32, @sizeOf(OptBoth32))
    }) catch unreachable;

    // Field details for 64-bit
    stdout.print("64-bit Field Layout Details:\n", .{}) catch unreachable;
    stdout.print("  Current.ref_count offset: {}\n", .{@offsetOf(Current, "ref_count")}) catch unreachable;
    stdout.print("  Current.group_node offset: {}\n", .{@offsetOf(Current, "group_node")}) catch unreachable;
    stdout.print("  Current.state offset: {}\n\n", .{@offsetOf(Current, "state")}) catch unreachable;

    stdout.print("  OptBoth.ref_count offset: {}\n", .{@offsetOf(OptBoth, "ref_count")}) catch unreachable;
    stdout.print("  OptBoth.group_node offset: {}\n", .{@offsetOf(OptBoth, "group_node")}) catch unreachable;
    stdout.print("  OptBoth.state offset: {}\n", .{@offsetOf(OptBoth, "state")}) catch unreachable;
}
