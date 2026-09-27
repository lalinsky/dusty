//! The memory a request is served with -- the buffer its head is read
//! into and the arena everything else comes from -- shared by a server's
//! connections rather than held by each. A connection takes a set when a
//! request arrives and gives it back once nothing is buffered after the
//! response, so the memory in use follows the requests being served, not
//! the connections kept open.
//!
//! Sets are never freed until the pool is, and each keeps what its arena
//! grew to: the pool settles at the most requests ever served at once.

const std = @import("std");

/// A request's read buffer and arena, in one allocation with this header.
pub const RequestBuffers = struct {
    arena: std.heap.ArenaAllocator,
    read_buffer: []u8,
    /// Where this sits in the pool's slots.
    index: u32,
    /// The set below this one on the free stack. Written by whoever pushes
    /// it, and read by a pop that may be losing a race to take it, so it is
    /// only ever accessed atomically.
    next: u32 = none,
};

const none = std.math.maxInt(u32);

pub const RequestBuffersPool = struct {
    allocator: std.mem.Allocator,
    read_buffer_len: usize,
    /// Primed into each arena, so an ordinary request is served without
    /// growing it.
    arena_reserve: usize,
    /// The free stack's top: an index in the low half, and in the high half
    /// a count of the changes to it. A pop that read the top and then lost
    /// the CPU could otherwise find the same set on top when it resumes,
    /// taken and given back in the meantime with another below it, and put
    /// a set still in use back on top.
    top: std.atomic.Value(u64) = .init(pack(none, 0)),
    /// Sets ever created, which is the next index.
    count: std.atomic.Value(u32) = .init(0),
    /// The slots, in chunks that double in size and never move, so an index
    /// read off a stale top still names a set.
    chunks: [chunk_count]std.atomic.Value(?[*]?*RequestBuffers) = @splat(.init(null)),

    const first_chunk_bits = 6;
    const chunk_count = 32 - first_chunk_bits;

    pub fn init(allocator: std.mem.Allocator, read_buffer_len: usize, arena_reserve: usize) RequestBuffersPool {
        return .{
            .allocator = allocator,
            .read_buffer_len = read_buffer_len,
            .arena_reserve = arena_reserve,
        };
    }

    /// Only once every set is back.
    pub fn deinit(self: *RequestBuffersPool) void {
        // By chunk rather than by index: a failed allocation leaves an index
        // counted with no set, or with no chunk at all.
        for (&self.chunks, 0..) |*chunk, k| {
            const slots = chunk.load(.acquire) orelse continue;
            for (slots[0..chunkLen(k)]) |maybe_buffers| {
                const buffers = maybe_buffers orelse continue;
                buffers.arena.deinit();
                self.allocator.free(allocation(buffers, self.read_buffer_len));
            }
            self.allocator.free(slots[0..chunkLen(k)]);
        }
        self.* = undefined;
    }

    /// A free set, or a new one if none is.
    pub fn acquire(self: *RequestBuffersPool) std.mem.Allocator.Error!*RequestBuffers {
        var top = self.top.load(.acquire);
        while (indexOf(top) != none) {
            const buffers = self.slot(indexOf(top)).*.?;
            const next = @atomicLoad(u32, &buffers.next, .monotonic);
            top = self.top.cmpxchgWeak(top, pack(next, tagOf(top) +% 1), .acquire, .acquire) orelse return buffers;
        }
        return self.create();
    }

    /// Gives a set back, its arena reset.
    pub fn release(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        _ = buffers.arena.reset(.retain_capacity);
        var top = self.top.load(.monotonic);
        while (true) {
            @atomicStore(u32, &buffers.next, indexOf(top), .monotonic);
            top = self.top.cmpxchgWeak(top, pack(buffers.index, tagOf(top) +% 1), .release, .monotonic) orelse return;
        }
    }

    fn create(self: *RequestBuffersPool) std.mem.Allocator.Error!*RequestBuffers {
        const index = self.count.fetchAdd(1, .monotonic);
        // Past this, `position` runs off the last chunk.
        std.debug.assert(index < (1 << 32) - (1 << first_chunk_bits));
        const slot_ptr = try self.slotAllocating(index);

        const size = std.math.add(usize, @sizeOf(RequestBuffers), self.read_buffer_len) catch return error.OutOfMemory;
        const memory = try self.allocator.alignedAlloc(u8, .of(RequestBuffers), size);
        const buffers: *RequestBuffers = @ptrCast(memory.ptr);
        buffers.* = .{
            .arena = .init(self.allocator),
            .read_buffer = memory[@sizeOf(RequestBuffers)..],
            .index = index,
        };
        errdefer {
            buffers.arena.deinit();
            self.allocator.free(memory);
        }
        // Reset keeps the memory, as one node the requests are then carved
        // from.
        _ = try buffers.arena.allocator().alloc(u8, self.arena_reserve);
        _ = buffers.arena.reset(.retain_capacity);

        slot_ptr.* = buffers;
        return buffers;
    }

    fn allocation(buffers: *RequestBuffers, read_buffer_len: usize) []align(@alignOf(RequestBuffers)) u8 {
        const base: [*]align(@alignOf(RequestBuffers)) u8 = @ptrCast(buffers);
        return base[0 .. @sizeOf(RequestBuffers) + read_buffer_len];
    }

    fn slot(self: *RequestBuffersPool, index: u32) *?*RequestBuffers {
        const k, const offset = position(index);
        return &self.chunks[k].load(.acquire).?[offset];
    }

    fn slotAllocating(self: *RequestBuffersPool, index: u32) std.mem.Allocator.Error!*?*RequestBuffers {
        const k, const offset = position(index);
        const slots = self.chunks[k].load(.acquire) orelse blk: {
            const fresh = try self.allocator.alloc(?*RequestBuffers, chunkLen(k));
            @memset(fresh, null);
            // Two creators can reach a new chunk at once; the one that loses
            // uses the winner's.
            if (self.chunks[k].cmpxchgStrong(null, fresh.ptr, .acq_rel, .acquire)) |winner| {
                self.allocator.free(fresh);
                break :blk winner.?;
            }
            break :blk fresh.ptr;
        };
        return &slots[offset];
    }

    /// Chunk `k` holds `2^(first_chunk_bits + k)` slots, after all the
    /// chunks before it.
    fn position(index: u32) struct { usize, usize } {
        const n = @as(u64, index) + (1 << first_chunk_bits);
        const bits = std.math.log2_int(u64, n);
        return .{ bits - first_chunk_bits, @intCast(n - (@as(u64, 1) << bits)) };
    }

    fn chunkLen(k: usize) usize {
        return @as(usize, 1) << @intCast(first_chunk_bits + k);
    }

    fn pack(index: u32, tag: u32) u64 {
        return @as(u64, tag) << 32 | index;
    }

    fn indexOf(top: u64) u32 {
        return @truncate(top);
    }

    fn tagOf(top: u64) u32 {
        return @truncate(top >> 32);
    }
};

test "RequestBuffersPool: a set given back is the next one taken" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, 128, 256);
    defer pool.deinit();

    const a = try pool.acquire();
    const b = try pool.acquire();
    try std.testing.expect(a != b);
    try std.testing.expectEqual(128, a.read_buffer.len);

    pool.release(a);
    pool.release(b);
    try std.testing.expectEqual(b, try pool.acquire());
    try std.testing.expectEqual(a, try pool.acquire());
    // Both are out, so this one is new.
    const c = try pool.acquire();
    try std.testing.expect(c != a and c != b);
    pool.release(a);
    pool.release(b);
    pool.release(c);
}

test "RequestBuffersPool: slots past the first chunk" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, 16, 16);
    defer pool.deinit();

    var taken: [200]*RequestBuffers = undefined;
    for (&taken) |*buffers| buffers.* = try pool.acquire();
    for (taken) |buffers| pool.release(buffers);
    try std.testing.expectEqual(200, pool.count.load(.monotonic));
}

test "RequestBuffersPool: deinit after a set could not get a chunk" {
    // The first chunk, then a set and its arena's reserve for each of its
    // 64 slots: the next allocation is the second chunk.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 + 64 * 2 });
    var pool: RequestBuffersPool = .init(failing.allocator(), 16, 16);
    defer pool.deinit();

    var taken: [64]*RequestBuffers = undefined;
    for (&taken) |*buffers| buffers.* = try pool.acquire();
    try std.testing.expectError(error.OutOfMemory, pool.acquire());
    for (taken) |buffers| pool.release(buffers);
}

test "RequestBuffersPool: a set is never held by two threads at once" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, 16, 16);
    defer pool.deinit();

    const Worker = struct {
        fn run(p: *RequestBuffersPool, failed: *std.atomic.Value(bool)) void {
            for (0..20_000) |_| {
                const buffers = p.acquire() catch return failed.store(true, .monotonic);
                // The read buffer's first byte marks it taken.
                const mark: *u8 = &buffers.read_buffer[0];
                if (@atomicRmw(u8, mark, .Xchg, 1, .acq_rel) != 0) failed.store(true, .monotonic);
                @atomicStore(u8, mark, 0, .release);
                p.release(buffers);
            }
        }
    };

    // More than the workers can hold at once, so none is created while
    // they run, and each starts with its mark clear.
    var initial: [8]*RequestBuffers = undefined;
    for (&initial) |*buffers| {
        buffers.* = try pool.acquire();
        buffers.*.read_buffer[0] = 0;
    }
    for (initial) |buffers| pool.release(buffers);

    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &failed });
    for (threads) |t| t.join();
    try std.testing.expect(!failed.load(.monotonic));
    try std.testing.expectEqual(8, pool.count.load(.monotonic));
}
