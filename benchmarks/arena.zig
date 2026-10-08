//! Compares std.heap.ArenaAllocator with src/Arena.zig on a few workloads.
//!
//!     zig run -OReleaseFast --dep arena -Mroot=benchmarks/arena.zig -Marena=src/Arena.zig
const std = @import("std");
const Arena = @import("arena");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Counting = struct {
    child: Allocator,
    allocs: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn grow(self: *Counting, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }
    fn alloc(ctx: *anyopaque, n: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(n, a, ra) orelse return null;
        self.allocs += 1;
        self.grow(0, n);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.grow(m.len, n);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.grow(m.len, n);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.grow(m.len, 0);
    }
};

/// The two ways of getting nested lifetimes: separate std arenas reset with
/// retain_capacity, or snapshots of one Arena.
const Kind = enum { std_arena, arena, arena_no_free_lists, arena_no_large_cache };

const Scopes = struct {
    kind: Kind,
    // std: one arena per level
    std_levels: [3]std.heap.ArenaAllocator = undefined,
    arena: Arena = undefined,
    snaps: [3]Arena.Snapshot = undefined,

    fn init(kind: Kind, child: Allocator) Scopes {
        var s: Scopes = .{ .kind = kind };
        switch (kind) {
            .std_arena => for (&s.std_levels) |*l| {
                l.* = .init(child);
            },
            .arena => s.arena = .init(child, .{}),
            .arena_no_free_lists => s.arena = .init(child, .{ .free_lists = false }),
            .arena_no_large_cache => s.arena = .init(child, .{ .large_cache_limit = 0 }),
        }
        return s;
    }
    fn deinit(s: *Scopes) void {
        switch (s.kind) {
            .std_arena => for (&s.std_levels) |*l| l.deinit(),
            else => s.arena.deinit(),
        }
    }
    fn alloc(s: *Scopes, level: usize) Allocator {
        return switch (s.kind) {
            .std_arena => s.std_levels[level].allocator(),
            else => s.arena.allocator(),
        };
    }
    fn begin(s: *Scopes, level: usize) !void {
        switch (s.kind) {
            .std_arena => {},
            else => s.snaps[level] = try s.arena.snapshot(),
        }
    }
    fn end(s: *Scopes, level: usize) void {
        switch (s.kind) {
            .std_arena => _ = s.std_levels[level].reset(.retain_capacity),
            else => s.arena.release(s.snaps[level]),
        }
    }
};

/// Roughly what a request does: headers, a query map, a body grown in pieces
/// with small allocations between, and a few scratch scopes.
fn request(s: *Scopes, random: std.Random) !void {
    try s.begin(1);
    defer s.end(1);
    const a = s.alloc(1);
    for (0..12) |i| {
        const name = try a.alloc(u8, 8 + i);
        @memset(name, 'n');
        const value = try a.alloc(u8, 10 + random.uintLessThan(usize, 50));
        @memset(value, 'v');
        std.mem.doNotOptimizeAway(value.ptr);
    }
    var query: std.StringHashMapUnmanaged([]const u8) = .empty;
    const keys = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg", "hhhhhhhh" };
    for (keys) |k| try query.put(a, k, try a.dupe(u8, k));
    var body: std.ArrayList(u8) = .empty;
    for (0..40) |i| {
        try body.appendNTimes(a, 'x', 50);
        if (i % 4 == 0) std.mem.doNotOptimizeAway((try std.fmt.allocPrint(a, "line {d}", .{i})).ptr);
    }
    for (0..3) |_| {
        try s.begin(2);
        defer s.end(2);
        const scratch = s.alloc(2);
        for (0..20) |_| std.mem.doNotOptimizeAway((try scratch.alloc(u8, 16 + random.uintLessThan(usize, 100))).ptr);
    }
    std.mem.doNotOptimizeAway(body.items.ptr);
}

/// Several lists grown at once, the worst case for a bump allocator.
fn lists(s: *Scopes, random: std.Random) !void {
    try s.begin(1);
    defer s.end(1);
    const a = s.alloc(1);
    var ls: [4]std.ArrayList(u32) = @splat(.empty);
    for (0..50_000) |i| {
        for (&ls) |*l| try l.append(a, @truncate(i));
        if (i % 64 == 0) std.mem.doNotOptimizeAway((try a.alloc(u8, 8 + random.uintLessThan(usize, 64))).ptr);
    }
    for (&ls) |*l| std.mem.doNotOptimizeAway(l.items.ptr);
}

/// Medium lists built side by side and dropped, over and over, in one scope:
/// a JSON encoder's buffers, say. Only reuse keeps this from growing.
fn medium(s: *Scopes, random: std.Random) !void {
    try s.begin(1);
    defer s.end(1);
    const a = s.alloc(1);
    for (0..50) |_| {
        var ls: [4]std.ArrayList(u8) = @splat(.empty);
        const target = 1000 + random.uintLessThan(usize, 6000);
        for (0..target) |i| {
            for (&ls) |*l| try l.append(a, @truncate(i));
        }
        for (&ls) |*l| l.deinit(a);
    }
}

/// Many small allocations and a reset: the bump path alone.
fn small(s: *Scopes, random: std.Random) !void {
    try s.begin(1);
    defer s.end(1);
    const a = s.alloc(1);
    for (0..10_000) |_| {
        const m = try a.alignedAlloc(u8, .@"8", 8 + random.uintLessThan(usize, 56));
        m[0] = 1;
        std.mem.doNotOptimizeAway(m.ptr);
    }
}

fn run(io: std.Io, gpa: Allocator, kind: Kind, comptime name: []const u8, comptime work: anytype, iterations: usize) !void {
    var counting: Counting = .{ .child = gpa };
    var s: Scopes = .init(kind, counting.allocator());
    defer s.deinit();
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    // Warm up, so the arenas have grown.
    for (0..10) |_| try work(&s, random);
    const allocs_before = counting.allocs;
    // Best of several, the machine being noisy.
    var ns: i96 = std.math.maxInt(i96);
    for (0..7) |_| {
        const start: std.Io.Timestamp = .now(io, .awake);
        for (0..iterations) |_| try work(&s, random);
        ns = @min(ns, start.durationTo(.now(io, .awake)).nanoseconds);
    }
    std.debug.print("{s:<8} {s:<20} {d:>10.1} ns/iter  peak {d:>9} B  child allocs/iter {d:.2}\n", .{
        name,
        @tagName(kind),
        @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations)),
        counting.peak,
        @as(f64, @floatFromInt(counting.allocs - allocs_before)) / @as(f64, @floatFromInt(iterations * 7)),
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    inline for (.{ .{ "request", request, 200_000 }, .{ "lists", lists, 200 }, .{ "medium", medium, 200 }, .{ "small", small, 2_000 } }) |w| {
        for ([_]Kind{ .std_arena, .arena, .arena_no_free_lists, .arena_no_large_cache }) |kind| {
            try run(init.io, gpa, kind, w[0], w[1], w[2]);
        }
    }
}
