const std = @import("std");

// Simulating the current Awaitable structure based on issue #50
// This represents the "before" state with potential optimizations identified

const AwaitableCurrentLayout = struct {
    // Theory #1: ref_count is currently larger than u8 (likely usize or u32)
    // Let's test with both usize and u32 to show different scenarios
    ref_count: usize, // Could be u32 on 32-bit, usize on 64-bit

    // Theory #2: group_node is optional, making the group pointer non-optional
    // This means we have an optional struct containing a non-optional pointer
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },

    // Additional typical fields that might be in an awaitable
    state: enum(u8) { pending, resolved, rejected },
};

// For 32-bit testing
const AwaitableCurrentLayoutWith32BitPtr = struct {
    ref_count: u32,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};


// Optimization #1: ref_count as u8
const AwaitableOptimized1 = struct {
    ref_count: u8,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const AwaitableOptimized1With32BitPtr = struct {
    ref_count: u8,
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

// Optimization #2: group_node non-optional, group pointer optional
const AwaitableOptimized2 = struct {
    ref_count: usize,
    group_node: struct {
        group: ?*anyopaque, // Now optional
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const AwaitableOptimized2With32BitPtr = struct {
    ref_count: u32,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

// Both optimizations combined
const AwaitableOptimizedBoth = struct {
    ref_count: u8,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

const AwaitableOptimizedBothWith32BitPtr = struct {
    ref_count: u8,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};

fn analyzeLayout(comptime T: type, name: []const u8) void {
    const size = @sizeOf(T);
    const alignment = @alignOf(T);

    std.debug.print("{s}:\n", .{name});
    std.debug.print("  Size: {d} bytes\n", .{size});
    std.debug.print("  Alignment: {d} bytes\n", .{alignment});

    // Analyze field offsets
    inline for (@typeInfo(T).@"struct".fields) |field| {
        std.debug.print("  Field '{s}': offset={d}, size={d}\n", .{
            field.name,
            @offsetOf(T, field.name),
            @sizeOf(field.type),
        });
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    const pointer_size = @sizeOf(*anyopaque);

    std.debug.print("=== Awaitable Memory Layout Analysis ===\n\n", .{});
    std.debug.print("Platform: {s} ({d}-bit)\n", .{
        @tagName(@import("builtin").target.cpu.arch),
        pointer_size * 8,
    });
    std.debug.print("Pointer size: {d} bytes\n\n", .{pointer_size});

    // Analyze current platform (64-bit in most cases)
    std.debug.print("=== Current Platform Analysis ===\n", .{});
    analyzeLayout(AwaitableCurrentLayout, "Current (ref_count: usize)");

    std.debug.print("=== Optimization #1: ref_count as u8 ===\n", .{});
    analyzeLayout(AwaitableOptimized1, "Optimized with u8 ref_count");
    const savings1 = @as(i64, @sizeOf(AwaitableCurrentLayout)) - @as(i64, @sizeOf(AwaitableOptimized1));
    std.debug.print("Savings: {d} bytes ({d}%)\n\n", .{
        savings1,
        @divFloor(savings1 * 100, @as(i64, @sizeOf(AwaitableCurrentLayout))),
    });

    std.debug.print("=== Optimization #2: group_node non-optional, group pointer optional ===\n", .{});
    analyzeLayout(AwaitableOptimized2, "Optimized with optional group pointer");
    const savings2 = @as(i64, @sizeOf(AwaitableCurrentLayout)) - @as(i64, @sizeOf(AwaitableOptimized2));
    std.debug.print("Savings: {d} bytes ({d}%)\n\n", .{
        savings2,
        @divFloor(savings2 * 100, @as(i64, @sizeOf(AwaitableCurrentLayout))),
    });

    std.debug.print("=== Both Optimizations Combined ===\n", .{});
    analyzeLayout(AwaitableOptimizedBoth, "Optimized with both changes");
    const savings_both = @as(i64, @sizeOf(AwaitableCurrentLayout)) - @as(i64, @sizeOf(AwaitableOptimizedBoth));
    std.debug.print("Savings: {d} bytes ({d}%)\n\n", .{
        savings_both,
        @divFloor(savings_both * 100, @as(i64, @sizeOf(AwaitableCurrentLayout))),
    });

    // Simulate 32-bit analysis
    std.debug.print("\n=== Simulated 32-bit Platform Analysis ===\n", .{});
    std.debug.print("(Using 32-bit pointer size simulation)\n\n", .{});

    std.debug.print("Current Layout (32-bit simulation):\n", .{});
    std.debug.print("  Size: {d} bytes\n\n", .{@sizeOf(AwaitableCurrentLayoutWith32BitPtr)});

    std.debug.print("Optimization #1 (u8 ref_count, 32-bit):\n", .{});
    std.debug.print("  Size: {d} bytes\n", .{@sizeOf(AwaitableOptimized1With32BitPtr)});
    const savings1_32 = @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr)) - @as(i64, @sizeOf(AwaitableOptimized1With32BitPtr));
    std.debug.print("  Savings: {d} bytes ({d}%)\n\n", .{
        savings1_32,
        @divFloor(savings1_32 * 100, @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr))),
    });

    std.debug.print("Optimization #2 (optional group pointer, 32-bit):\n", .{});
    std.debug.print("  Size: {d} bytes\n", .{@sizeOf(AwaitableOptimized2With32BitPtr)});
    const savings2_32 = @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr)) - @as(i64, @sizeOf(AwaitableOptimized2With32BitPtr));
    std.debug.print("  Savings: {d} bytes ({d}%)\n\n", .{
        savings2_32,
        @divFloor(savings2_32 * 100, @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr))),
    });

    std.debug.print("Both Optimizations (32-bit):\n", .{});
    std.debug.print("  Size: {d} bytes\n", .{@sizeOf(AwaitableOptimizedBothWith32BitPtr)});
    const savings_both_32 = @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr)) - @as(i64, @sizeOf(AwaitableOptimizedBothWith32BitPtr));
    std.debug.print("  Savings: {d} bytes ({d}%)\n\n", .{
        savings_both_32,
        @divFloor(savings_both_32 * 100, @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr))),
    });

    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Theory #1 (ref_count as u8):\n", .{});
    std.debug.print("  - Reduces ref_count from 8 bytes (usize on 64-bit) to 1 byte\n", .{});
    std.debug.print("  - Reduces ref_count from 4 bytes (u32 on 32-bit) to 1 byte\n", .{});
    std.debug.print("  - Actual savings depend on struct alignment and field ordering\n", .{});
    std.debug.print("  - 64-bit savings: {d} bytes, 32-bit savings: {d} bytes\n\n", .{ savings1, savings1_32 });

    std.debug.print("Theory #2 (group_node non-optional, group pointer optional):\n", .{});
    std.debug.print("  - Zig's optional encoding for structs adds a boolean tag\n", .{});
    std.debug.print("  - Moving the optional to the pointer level uses null representation\n", .{});
    std.debug.print("  - Pointers can be null without extra tag byte\n", .{});
    std.debug.print("  - 64-bit savings: {d} bytes, 32-bit savings: {d} bytes\n\n", .{ savings2, savings2_32 });

    std.debug.print("Both optimizations combined:\n", .{});
    std.debug.print("  - 64-bit savings: {d} bytes ({d}%)\n", .{
        savings_both,
        @divFloor(savings_both * 100, @as(i64, @sizeOf(AwaitableCurrentLayout))),
    });
    std.debug.print("  - 32-bit savings: {d} bytes ({d}%)\n", .{
        savings_both_32,
        @divFloor(savings_both_32 * 100, @as(i64, @sizeOf(AwaitableCurrentLayoutWith32BitPtr))),
    });
}
