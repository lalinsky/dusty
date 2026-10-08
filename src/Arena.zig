//! A single-threaded arena with snapshots.
//!
//! Memory is bumped out of chunks taken from `child`. `snapshot` marks the
//! current position, `restore` rolls everything allocated since back and
//! keeps the snapshot to come back to again, and `release` rolls back and
//! drops it. So one arena can serve nested lifetimes -- a connection, the
//! requests on it, the scratch work of a request -- without an arena for
//! each. Chunks rolled back over are kept as spares and bumped into again, so
//! a loop of snapshot and restore stops reaching `child` once it has warmed
//! up.
//!
//! Two things keep growing buffers, an `ArrayList` say, from wasting memory
//! when other allocations land between their growths:
//!
//! - An allocation of `large_threshold` bytes or more gets its own block from
//!   `child`, and resizing it is `child`'s resize or remap, which for the page
//!   allocator is `mremap` and copies nothing. Blocks given back, by a free or
//!   a restore, are kept up to `large_cache_limit` bytes and handed out
//!   again, so a buffer that grew large once does not go through `child`
//!   every time it grows.
//! - A smaller allocation that is freed and is not the most recent one goes
//!   on a free list by size class, and later allocations of that size reuse
//!   it. Freeing or shrinking the most recent allocation simply moves the
//!   bump position back.
//!
//! Each snapshot starts with empty free lists, a restore empties them again,
//! and a release puts back the ones that were there when the snapshot was
//! taken. So what was allocated inside a snapshot never takes memory that
//! outlives it, and what outlives it is never handed out inside it. Something
//! freed inside a snapshot that was allocated before it is only reused until
//! the snapshot is rolled back, and then waits for the next reset.
//!
//! The rule that comes with snapshots: nothing allocated after a snapshot may
//! be used after restoring it. That includes growing a buffer that was
//! allocated before the snapshot -- its new memory is allocated after it. In
//! safe builds a restore overwrites what it released with `undefined`, so a
//! use after it is likely to show.

const Arena = @This();

child: Allocator,
large_threshold: usize,
min_chunk_size: usize,
max_chunk_size: usize,
free_lists_enabled: bool,

/// All chunks, oldest first. The ones after `chunk` are spares.
first_chunk: ?*Chunk = null,
/// The chunk being bumped into, or null before the first allocation and after
/// a reset.
chunk: ?*Chunk = null,
/// Bump position and end, as addresses in `chunk`.
pos: usize = 0,
end: usize = 0,
next_chunk_size: usize,

/// Large blocks, newest first.
large: ?*Large = null,
large_seq: usize = 0,
/// Large blocks given back, for reuse.
large_cache: ?*Large = null,
large_cache_bytes: usize = 0,
large_cache_limit: usize,

free_lists: [class_count]?*FreeBlock = @splat(null),
/// The classes with blocks, so allocating with nothing freed costs one test.
free_mask: FreeMask = 0,

/// The innermost snapshot.
frame: ?*Frame = null,
frame_seq: usize = 0,

pub const Options = struct {
    /// The first chunk's size, header included.
    min_chunk_size: usize = 4 * 1024,
    /// Chunks double in size up to this.
    max_chunk_size: usize = 256 * 1024,
    /// Allocations of at least this many bytes get their own block from the
    /// child allocator. Lower means less left behind when a buffer outgrows
    /// a chunk, and more trips to the child allocator.
    large_threshold: usize = 16 * 1024,
    /// How many bytes of large blocks given back are kept for reuse.
    large_cache_limit: usize = 1024 * 1024,
    /// Whether freed allocations are kept for reuse. Without, freeing
    /// anything but the most recent allocation does nothing.
    free_lists: bool = true,
};

pub fn init(child: Allocator, options: Options) Arena {
    std.debug.assert(options.min_chunk_size <= options.max_chunk_size);
    std.debug.assert(options.large_threshold <= options.max_chunk_size);
    return .{
        .child = child,
        .large_threshold = options.large_threshold,
        .large_cache_limit = options.large_cache_limit,
        .min_chunk_size = options.min_chunk_size,
        .max_chunk_size = options.max_chunk_size,
        .free_lists_enabled = options.free_lists,
        .next_chunk_size = options.min_chunk_size,
    };
}

pub fn deinit(arena: *Arena) void {
    arena.large_cache_limit = 0;
    arena.freeLargeFrom(0);
    arena.freeLargeCacheBeyond(0);
    var it = arena.first_chunk;
    while (it) |c| {
        it = c.next;
        arena.child.rawFree(c.allocatedSlice(), .of(Chunk), @returnAddress());
    }
    arena.* = undefined;
}

pub fn allocator(arena: *Arena) Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// A position `restore` can go back to. Valid until it is released, a
/// snapshot taken before it is restored or released, or the arena is reset.
pub const Snapshot = struct {
    frame: *Frame,
    seq: usize,
};

/// What a snapshot keeps, at the position it marks.
const Frame = struct {
    prev: ?*Frame,
    seq: usize,
    /// Where the snapshot was taken, which `release` goes back to.
    chunk: ?*Chunk,
    pos: usize,
    /// The chunk the frame itself is in, and `restore` goes back to right
    /// past it.
    own_chunk: *Chunk,
    large_seq: usize,
    free_lists: [class_count]?*FreeBlock,
    free_mask: FreeMask,
};

/// Marks where the arena is, for `restore` and `release` to go back to. It
/// takes a little of the arena, for what it has to remember.
pub fn snapshot(arena: *Arena) Allocator.Error!Snapshot {
    // The position before the frame is the one to go back to; the frame sits
    // past it, so nothing allocated before can grow over it in place.
    const chunk = arena.chunk;
    const pos = arena.pos;
    // From before the frame too: moving to a new chunk for it puts the rest
    // of this one on the free lists, and `release` comes back to it.
    const free_lists = arena.free_lists;
    const free_mask = arena.free_mask;
    const ptr = try arena.bump(@sizeOf(Frame), .of(Frame));
    const frame: *Frame = @ptrCast(@alignCast(ptr));
    arena.frame_seq += 1;
    frame.* = .{
        .prev = arena.frame,
        .seq = arena.frame_seq,
        .chunk = chunk,
        .pos = pos,
        .own_chunk = arena.chunk.?,
        .large_seq = arena.large_seq,
        .free_lists = free_lists,
        .free_mask = free_mask,
    };
    arena.frame = frame;
    arena.free_lists = @splat(null);
    arena.free_mask = 0;
    return .{ .frame = frame, .seq = frame.seq };
}

/// Releases everything allocated since `s` was taken, and the snapshots taken
/// since with it. `s` stays, to be restored again.
pub fn restore(arena: *Arena, s: Snapshot) void {
    arena.checkSnapshot(s);
    const frame = s.frame;
    arena.freeLargeFrom(frame.large_seq);
    arena.free_lists = @splat(null);
    arena.free_mask = 0;
    arena.frame = frame;
    arena.rewind(frame.own_chunk, @intFromPtr(frame) + @sizeOf(Frame));
}

/// Like `restore`, and releases `s` itself too, so the arena is as it was
/// right before `s` was taken.
pub fn release(arena: *Arena, s: Snapshot) void {
    arena.checkSnapshot(s);
    const frame = s.frame.*;
    arena.freeLargeFrom(frame.large_seq);
    arena.free_lists = frame.free_lists;
    arena.free_mask = frame.free_mask;
    arena.frame = frame.prev;
    arena.rewind(frame.chunk, frame.pos);
}

fn checkSnapshot(arena: *const Arena, s: Snapshot) void {
    if (!std.debug.runtime_safety) return;
    // It must be on the stack, and still the same snapshot: a frame's memory
    // is reused once the snapshot is gone.
    var it = arena.frame;
    while (it) |f| : (it = f.prev) {
        if (f == s.frame) break;
    } else @panic("Arena: snapshot is no longer valid");
    if (s.frame.seq != s.seq) @panic("Arena: snapshot is no longer valid");
}

pub const ResetMode = union(enum) {
    /// Keep every chunk, and the large blocks up to `large_cache_limit`.
    retain_capacity,
    /// Keep the oldest chunks, and then large blocks, up to this many bytes
    /// in all.
    retain_with_limit: usize,
    free_all,
};

/// Releases everything, and all snapshots.
pub fn reset(arena: *Arena, mode: ResetMode) void {
    arena.freeLargeFrom(0);
    arena.free_lists = @splat(null);
    arena.free_mask = 0;
    arena.frame = null;
    arena.rewind(null, 0);
    switch (mode) {
        .retain_capacity => {},
        .retain_with_limit => |limit| {
            const kept = arena.freeChunksBeyond(&arena.first_chunk, limit);
            arena.freeLargeCacheBeyond(limit - kept);
        },
        .free_all => {
            _ = arena.freeChunksBeyond(&arena.first_chunk, 0);
            arena.freeLargeCacheBeyond(0);
        },
    }
}

/// Gives the spare chunks and the cached large blocks back to the child
/// allocator, past the first `keep_bytes` of them.
pub fn trim(arena: *Arena, keep_bytes: usize) void {
    const spares = if (arena.chunk) |c| &c.next else &arena.first_chunk;
    const kept = arena.freeChunksBeyond(spares, keep_bytes);
    arena.freeLargeCacheBeyond(keep_bytes - kept);
}

/// Makes sure the arena holds a chunk with at least `bytes` free, so that
/// much can be allocated without reaching the child allocator.
pub fn preheat(arena: *Arena, bytes: usize) Allocator.Error!void {
    if (arena.end - arena.pos >= bytes) return;
    try arena.nextChunk(bytes, .@"1");
}

/// The bytes held from the child allocator, chunk and block headers, spare
/// chunks and cached blocks included.
pub fn queryCapacity(arena: *const Arena) usize {
    var total: usize = arena.large_cache_bytes;
    var it = arena.first_chunk;
    while (it) |c| : (it = c.next) total += c.size;
    var large = arena.large;
    while (large) |l| : (large = l.next) total += l.size;
    return total;
}

const Chunk = struct {
    next: ?*Chunk,
    /// Header included.
    size: usize,

    fn data(c: *Chunk) usize {
        return @intFromPtr(c) + @sizeOf(Chunk);
    }

    fn dataEnd(c: *Chunk) usize {
        return @intFromPtr(c) + c.size;
    }

    fn allocatedSlice(c: *Chunk) []u8 {
        return @as([*]u8, @ptrCast(c))[0..c.size];
    }
};

/// The header in front of a large allocation, at an offset that depends only
/// on its alignment, so it can be found from the allocation.
const Large = struct {
    prev: ?*Large,
    next: ?*Large,
    seq: usize,
    /// What the block holds, header included, which can be more than the
    /// allocation in it.
    size: usize,
    /// The block's, which is what it is freed with.
    alignment: Alignment,

    fn offset(alignment: Alignment) usize {
        return alignment.forward(@sizeOf(Large));
    }

    fn blockAlignment(alignment: Alignment) Alignment {
        return alignment.max(.of(Large));
    }

    fn fromMemory(memory: []u8, alignment: Alignment) *Large {
        return @ptrCast(@alignCast(memory.ptr - offset(alignment)));
    }

    fn allocatedSlice(l: *Large) []u8 {
        return @as([*]u8, @ptrCast(l))[0..l.size];
    }
};

/// Written into freed memory, which need not be aligned for it.
const FreeBlock = extern struct {
    next: ?*FreeBlock align(1),
    len: usize align(1),
};

/// Free lists hold blocks of at least 2^min_class bytes, in classes by
/// power of two; the last class holds all the bigger ones.
const min_class = 4;
const class_count = 13;
const FreeMask = u16;

comptime {
    std.debug.assert(@sizeOf(FreeBlock) <= 1 << min_class);
    std.debug.assert(class_count <= @bitSizeOf(FreeMask));
}

/// The class all of whose blocks fit `n` bytes, or the last.
fn allocClass(n: usize) usize {
    if (n <= 1 << min_class) return 0;
    return @min(std.math.log2_int_ceil(usize, n) - min_class, class_count - 1);
}

/// The class a block of `len` bytes goes on.
fn freeClass(len: usize) usize {
    std.debug.assert(len >= 1 << min_class);
    return @min(std.math.log2_int(usize, len) - min_class, class_count - 1);
}

fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    _ = ret_addr;
    if (n >= arena.large_threshold) return arena.allocLarge(n, alignment);
    if (arena.free_mask != 0) {
        if (arena.popFree(n, alignment)) |ptr| return ptr;
    }
    return arena.bump(n, alignment) catch null;
}

fn bump(arena: *Arena, n: usize, alignment: Alignment) Allocator.Error![*]u8 {
    const start = alignment.forward(arena.pos);
    if (start <= arena.end and arena.end - start >= n) {
        arena.pos = start + n;
        return @ptrFromInt(start);
    }
    try arena.nextChunk(n, alignment);
    const new_start = alignment.forward(arena.pos);
    arena.pos = new_start + n;
    return @ptrFromInt(new_start);
}

/// Moves to a chunk that fits `n` bytes at `alignment`: the first spare that
/// does, or a new one.
fn nextChunk(arena: *Arena, n: usize, alignment: Alignment) Allocator.Error!void {
    @branchHint(.cold);
    const needed = std.math.add(usize, n, alignment.toByteUnits() - 1) catch return error.OutOfMemory;

    // The tail of the current chunk is left behind; with free lists it can
    // still be used.
    if (arena.chunk != null) arena.pushFree(arena.pos, arena.end - arena.pos);

    const link = if (arena.chunk) |c| &c.next else &arena.first_chunk;
    var prev_link = link;
    while (prev_link.*) |spare| : (prev_link = &spare.next) {
        if (spare.size - @sizeOf(Chunk) >= needed) {
            // Unlink it from the spares and make it the next one.
            prev_link.* = spare.next;
            spare.next = link.*;
            link.* = spare;
            arena.useChunk(spare);
            return;
        }
    }

    const min_size = std.math.add(usize, @sizeOf(Chunk), needed) catch return error.OutOfMemory;
    const size = std.mem.alignForward(usize, @max(arena.next_chunk_size, min_size), @alignOf(Chunk));
    const ptr = arena.child.rawAlloc(size, .of(Chunk), @returnAddress()) orelse return error.OutOfMemory;
    const c: *Chunk = @ptrCast(@alignCast(ptr));
    c.* = .{ .next = link.*, .size = size };
    link.* = c;
    arena.useChunk(c);
    arena.next_chunk_size = @min(arena.next_chunk_size *| 2, arena.max_chunk_size);
}

fn useChunk(arena: *Arena, c: *Chunk) void {
    arena.chunk = c;
    arena.pos = c.data();
    arena.end = c.dataEnd();
}

/// Moves the bump position back to `pos` in `chunk`, null for before the
/// first chunk. The chunks after it are spares again.
fn rewind(arena: *Arena, chunk: ?*Chunk, pos: usize) void {
    if (std.debug.runtime_safety) {
        // From the position being gone back to, through the end of the
        // current chunk, everything is released.
        if (chunk) |c| {
            if (c == arena.chunk) {
                poison(pos, arena.pos);
            } else {
                poison(pos, c.dataEnd());
                var it = c.next;
                while (it) |spare| : (it = spare.next) {
                    poison(spare.data(), if (spare == arena.chunk) arena.pos else spare.dataEnd());
                    if (spare == arena.chunk) break;
                }
            }
        } else if (arena.chunk != null) {
            var it = arena.first_chunk;
            while (it) |spare| : (it = spare.next) {
                poison(spare.data(), if (spare == arena.chunk) arena.pos else spare.dataEnd());
                if (spare == arena.chunk) break;
            }
        }
    }
    if (chunk) |c| {
        arena.chunk = c;
        arena.pos = pos;
        arena.end = c.dataEnd();
    } else {
        arena.chunk = null;
        arena.pos = 0;
        arena.end = 0;
    }
}

fn poison(from: usize, to: usize) void {
    if (to > from) @memset(@as([*]u8, @ptrFromInt(from))[0 .. to - from], undefined);
}

/// Returns how many bytes it kept.
fn freeChunksBeyond(arena: *Arena, link: *?*Chunk, keep_bytes: usize) usize {
    var kept: usize = 0;
    var prev_link = link;
    while (prev_link.*) |c| {
        if (kept + c.size <= keep_bytes) {
            kept += c.size;
            prev_link = &c.next;
        } else {
            prev_link.* = c.next;
            arena.child.rawFree(c.allocatedSlice(), .of(Chunk), @returnAddress());
        }
    }
    // A shrunk arena grows on from the biggest chunk it kept.
    var biggest: usize = 0;
    var it = arena.first_chunk;
    while (it) |c| : (it = c.next) biggest = @max(biggest, c.size);
    arena.next_chunk_size = std.math.clamp(biggest *| 2, arena.min_chunk_size, arena.max_chunk_size);
    return kept;
}

fn allocLarge(arena: *Arena, n: usize, alignment: Alignment) ?[*]u8 {
    const offset = Large.offset(alignment);
    const size = std.math.add(usize, offset, n) catch return null;
    const block_alignment = Large.blockAlignment(alignment);
    const l: *Large = arena.takeLargeCache(size, block_alignment) orelse l: {
        const ptr = arena.child.rawAlloc(size, block_alignment, @returnAddress()) orelse return null;
        const l: *Large = @ptrCast(@alignCast(ptr));
        l.size = size;
        l.alignment = block_alignment;
        break :l l;
    };
    l.prev = null;
    l.next = arena.large;
    l.seq = arena.large_seq;
    const ptr: [*]u8 = @ptrCast(l);
    arena.large_seq += 1;
    if (arena.large) |head| head.prev = l;
    arena.large = l;
    return ptr + offset;
}

fn unlinkLarge(arena: *Arena, l: *Large) void {
    if (l.prev) |p| p.next = l.next else arena.large = l.next;
    if (l.next) |n| n.prev = l.prev;
}

/// The list is newest first, so the ones from `seq` on are at its head.
fn freeLargeFrom(arena: *Arena, seq: usize) void {
    while (arena.large) |l| {
        if (l.seq < seq) break;
        arena.large = l.next;
        arena.giveBackLarge(l);
    }
    if (arena.large) |l| l.prev = null;
}

/// Into the cache if there is room, to the child allocator if not.
fn giveBackLarge(arena: *Arena, l: *Large) void {
    if (arena.large_cache_bytes + l.size <= arena.large_cache_limit) {
        if (std.debug.runtime_safety) @memset(l.allocatedSlice()[@sizeOf(Large)..], undefined);
        l.next = arena.large_cache;
        arena.large_cache = l;
        arena.large_cache_bytes += l.size;
    } else {
        arena.child.rawFree(l.allocatedSlice(), l.alignment, @returnAddress());
    }
}

/// The smallest cached block that holds `size` bytes at `alignment`.
fn takeLargeCache(arena: *Arena, size: usize, alignment: Alignment) ?*Large {
    var best_link: ?*?*Large = null;
    var link = &arena.large_cache;
    while (link.*) |l| : (link = &l.next) {
        // Its address, not what it was allocated with, is what has to be
        // aligned; it is freed with what it was allocated with.
        if (l.size < size or !alignment.check(@intFromPtr(l))) continue;
        if (best_link == null or l.size < best_link.?.*.?.size) best_link = link;
    }
    const found = best_link orelse return null;
    const l = found.*.?;
    found.* = l.next;
    arena.large_cache_bytes -= l.size;
    return l;
}

fn freeLargeCacheBeyond(arena: *Arena, keep_bytes: usize) void {
    var kept: usize = 0;
    var link = &arena.large_cache;
    while (link.*) |l| {
        if (kept + l.size <= keep_bytes) {
            kept += l.size;
            link = &l.next;
        } else {
            link.* = l.next;
            arena.child.rawFree(l.allocatedSlice(), l.alignment, @returnAddress());
        }
    }
    arena.large_cache_bytes = kept;
}

fn pushFree(arena: *Arena, addr: usize, len: usize) void {
    if (!arena.free_lists_enabled or len < 1 << min_class) return;
    const class = freeClass(len);
    const block: *FreeBlock = @ptrFromInt(addr);
    block.* = .{ .next = arena.free_lists[class], .len = len };
    arena.free_lists[class] = block;
    arena.free_mask |= @as(FreeMask, 1) << @intCast(class);
}

/// Takes `n` bytes at `alignment` from a free block, putting back what is
/// left of it: one of the first few blocks of their own class that is long
/// enough -- the common case of something the size of what was freed -- or
/// else the first of the smallest class whose blocks all fit them.
fn popFree(arena: *Arena, n: usize, alignment: Alignment) ?[*]u8 {
    if (n >= 1 << min_class) {
        const own = freeClass(n);
        if (arena.free_mask & (@as(FreeMask, 1) << @intCast(own)) != 0) {
            if (arena.takeFree(own, n, alignment, 8)) |ptr| return ptr;
        }
    }
    const fitting = arena.free_mask & ~((@as(FreeMask, 1) << @intCast(allocClass(n))) - 1);
    if (fitting == 0) return null;
    return arena.takeFree(@ctz(fitting), n, alignment, 1);
}

/// The best fitting of the first `tries` blocks of `class`, for `n` bytes at
/// `alignment`.
fn takeFree(arena: *Arena, class: usize, n: usize, alignment: Alignment, tries: usize) ?[*]u8 {
    var best: ?*align(1) ?*FreeBlock = null;
    var best_spare: usize = std.math.maxInt(usize);
    var link: *align(1) ?*FreeBlock = &arena.free_lists[class];
    for (0..tries) |_| {
        const block = link.* orelse break;
        const addr = @intFromPtr(block);
        const start = alignment.forward(addr);
        if (start - addr <= block.len and block.len - (start - addr) >= n) {
            const spare = block.len - (start - addr) - n;
            if (spare < best_spare) {
                best = link;
                best_spare = spare;
                if (spare == 0) break;
            }
        }
        link = &block.next;
    }
    const found = best orelse return null;
    const block = found.*.?;
    const addr = @intFromPtr(block);
    const len = block.len;
    const start = alignment.forward(addr);
    found.* = block.next;
    if (arena.free_lists[class] == null) arena.free_mask &= ~(@as(FreeMask, 1) << @intCast(class));
    // What is in front of it, for alignment, is too little to bother with;
    // what is behind it goes back.
    arena.pushFree(start + n, addr + len - (start + n));
    return @ptrFromInt(start);
}

fn isLarge(arena: *const Arena, len: usize) bool {
    return len >= arena.large_threshold;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    // A block's kind follows from its length, so it must not change.
    if (arena.isLarge(memory.len) != arena.isLarge(new_len)) return false;
    if (arena.isLarge(memory.len)) {
        const l = Large.fromMemory(memory, alignment);
        const offset = Large.offset(alignment);
        // The block may well hold more than it was asked for; it keeps
        // what it has when shrunk.
        if (offset + new_len <= l.size) return true;
        if (!arena.child.rawResize(l.allocatedSlice(), l.alignment, offset + new_len, ret_addr)) return false;
        l.size = offset + new_len;
        return true;
    }
    const addr = @intFromPtr(memory.ptr);
    if (addr + memory.len == arena.pos) {
        // The most recent allocation: move the bump position.
        if (new_len <= memory.len) {
            arena.pos -= memory.len - new_len;
            return true;
        }
        if (arena.end - addr < new_len) return false;
        arena.pos = addr + new_len;
        return true;
    }
    if (new_len > memory.len) return false;
    arena.pushFree(addr + new_len, memory.len - new_len);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    if (arena.isLarge(memory.len) and arena.isLarge(new_len)) {
        const l = Large.fromMemory(memory, alignment);
        const offset = Large.offset(alignment);
        if (offset + new_len <= l.size) return memory.ptr;
        const new_ptr = arena.child.rawRemap(l.allocatedSlice(), l.alignment, offset + new_len, ret_addr) orelse return null;
        const moved: *Large = @ptrCast(@alignCast(new_ptr));
        moved.size = offset + new_len;
        if (moved != l) {
            if (moved.prev) |p| p.next = moved else arena.large = moved;
            if (moved.next) |n| n.prev = moved;
        }
        return new_ptr + offset;
    }
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    _ = ret_addr;
    if (arena.isLarge(memory.len)) {
        const l = Large.fromMemory(memory, alignment);
        arena.unlinkLarge(l);
        arena.giveBackLarge(l);
        return;
    }
    if (std.debug.runtime_safety) @memset(memory, undefined);
    const addr = @intFromPtr(memory.ptr);
    if (addr + memory.len == arena.pos) {
        arena.pos = addr;
        return;
    }
    arena.pushFree(addr, memory.len);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Counts what reaches the child allocator, to show what the arena takes.
const CountingAllocator = struct {
    child: Allocator,
    allocs: usize = 0,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = countAlloc,
            .resize = countResize,
            .remap = countRemap,
            .free = countFree,
        } };
    }

    fn grow(self: *CountingAllocator, old: usize, new: usize) void {
        self.live = self.live - old + new;
        self.peak = @max(self.peak, self.live);
    }

    fn countAlloc(ctx: *anyopaque, n: usize, a: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(n, a, ra) orelse return null;
        self.allocs += 1;
        self.grow(0, n);
        return ptr;
    }

    fn countResize(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, a, n, ra)) return false;
        self.grow(m.len, n);
        return true;
    }

    fn countRemap(ctx: *anyopaque, m: []u8, a: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(m, a, n, ra) orelse return null;
        self.grow(m.len, n);
        return ptr;
    }

    fn countFree(ctx: *anyopaque, m: []u8, a: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
        self.grow(m.len, 0);
    }
};

test "Arena: freeing the most recent allocation moves back" {
    var arena: Arena = .init(std.testing.allocator, .{});
    defer arena.deinit();
    const a = arena.allocator();

    const x = try a.alloc(u8, 10);
    const y = try a.alloc(u8, 20);
    a.free(y);
    const z = try a.alloc(u8, 20);
    try std.testing.expectEqual(y.ptr, z.ptr);
    try std.testing.expect(a.resize(z, 100));
    const grown: []u8 = z.ptr[0..100];
    try std.testing.expect(a.resize(grown, 5));
    // Not the most recent: can shrink, not grow.
    try std.testing.expect(!a.resize(x, 11));
    try std.testing.expect(a.resize(x, 4));
}

test "Arena: restore gives back the same memory, and stops reaching the child" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    var arena: Arena = .init(counting.allocator(), .{ .min_chunk_size = 1024 });
    defer arena.deinit();
    const a = arena.allocator();

    const base = try a.alloc(u8, 16);
    @memset(base, 'b');
    const s = try arena.snapshot();
    var first: ?[*]u8 = null;
    var allocs_after_warmup: usize = 0;
    for (0..10) |round| {
        // Enough to need several chunks.
        for (0..50) |i| {
            const m = try a.alloc(u8, 100 + i);
            if (i == 0) {
                if (first) |f| try std.testing.expectEqual(f, m.ptr) else first = m.ptr;
            }
        }
        arena.restore(s);
        if (round == 0) allocs_after_warmup = counting.allocs;
    }
    try std.testing.expectEqual(allocs_after_warmup, counting.allocs);
    try std.testing.expectEqualSlices(u8, "bbbbbbbbbbbbbbbb", base);
}

test "Arena: restoring an outer snapshot drops the inner ones" {
    var arena: Arena = .init(std.testing.allocator, .{});
    defer arena.deinit();
    const a = arena.allocator();

    const outer = try arena.snapshot();
    const x = try a.alloc(u8, 8);
    _ = try arena.snapshot();
    _ = try a.alloc(u8, 8);
    _ = try arena.snapshot();
    arena.restore(outer);
    try std.testing.expectEqual(outer.frame, arena.frame.?);
    const y = try a.alloc(u8, 8);
    try std.testing.expectEqual(x.ptr, y.ptr);
    arena.release(outer);
    try std.testing.expectEqual(null, arena.frame);
}

test "Arena: release goes back to before the snapshot" {
    var arena: Arena = .init(std.testing.allocator, .{});
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 8);
    const before = arena.pos;
    const outer = try arena.snapshot();
    const inner = try arena.snapshot();
    _ = try a.alloc(u8, 8);
    arena.restore(inner);
    arena.restore(inner);
    arena.release(inner);
    const inner2 = try arena.snapshot();
    // The same memory, but not the same snapshot.
    try std.testing.expectEqual(inner.frame, inner2.frame);
    try std.testing.expect(inner.seq != inner2.seq);
    arena.release(outer);
    try std.testing.expectEqual(before, arena.pos);
}

test "Arena: large allocations get their own block, freed on restore" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    var arena: Arena = .init(counting.allocator(), .{ .max_chunk_size = 16 * 1024, .large_threshold = 4 * 1024, .large_cache_limit = 0 });
    defer arena.deinit();
    const a = arena.allocator();

    const kept = try a.alloc(u8, 8 * 1024);
    @memset(kept, 'k');
    const s = try arena.snapshot();
    const live_before = counting.live;
    const big = try a.alignedAlloc(u8, .@"64", 100 * 1024);
    try std.testing.expect(std.mem.Alignment.@"64".check(@intFromPtr(big.ptr)));
    _ = try a.alloc(u8, 5000);
    try std.testing.expect(counting.live > live_before + 100 * 1024);
    arena.restore(s);
    // The large blocks are gone; the chunks stay.
    try std.testing.expect(counting.live < live_before + 16 * 1024);
    try std.testing.expectEqual(@as(u8, 'k'), kept[8 * 1024 - 1]);

    // One freed by itself, out of order.
    const l1 = try a.alloc(u8, 5000);
    const l2 = try a.alloc(u8, 6000);
    const l3 = try a.alloc(u8, 7000);
    a.free(l2);
    a.free(l1);
    a.free(l3);
    // Only the one from before the snapshot, itself a large block.
    try std.testing.expectEqual(Large.fromMemory(kept, .@"1"), arena.large.?);
    try std.testing.expectEqual(null, arena.large.?.next);
}

test "Arena: large blocks given back are reused" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    var arena: Arena = .init(counting.allocator(), .{ .large_threshold = 4 * 1024, .large_cache_limit = 64 * 1024 });
    defer arena.deinit();
    const a = arena.allocator();

    const s = try arena.snapshot();
    const x = try a.alloc(u8, 20 * 1024);
    const y = try a.alloc(u8, 30 * 1024);
    arena.restore(s);
    const allocs = counting.allocs;
    // The smaller one that fits.
    const z = try a.alloc(u8, 10 * 1024);
    try std.testing.expectEqual(x.ptr, z.ptr);
    // It grows into what the block has without the child allocator.
    try std.testing.expect(a.resize(z, 20 * 1024));
    // At another alignment, the same block, its allocation further in.
    const w = try a.alignedAlloc(u8, .@"16", 25 * 1024);
    try std.testing.expectEqual(Large.fromMemory(y, .@"1"), Large.fromMemory(w, .@"16"));
    try std.testing.expectEqual(allocs, counting.allocs);
    // Too much for the cache: this one goes back to the child allocator.
    const big = try a.alloc(u8, 100 * 1024);
    a.free(big);
    try std.testing.expectEqual(0, arena.large_cache_bytes);
    // Reused or not, a block has the alignment asked for.
    a.free(w);
    const page = try a.alignedAlloc(u8, .fromByteUnits(4096), 5 * 1024);
    try std.testing.expect(std.mem.Alignment.fromByteUnits(4096).check(@intFromPtr(page.ptr)));
    arena.trim(0);
    try std.testing.expectEqual(0, arena.large_cache_bytes);
}

test "Arena: a growing list does not leave its old buffers behind" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var list: std.ArrayList(u8) = .empty;
            var others: [64]*u64 = undefined;
            for (0..200_000) |i| {
                try list.append(gpa, @truncate(i));
                // Something else allocated in between, every so often.
                if (i % 4096 == 0) others[(i / 4096) % others.len] = try gpa.create(u64);
            }
            try std.testing.expectEqual(200_000, list.items.len);
        }
    };

    var counting_std: CountingAllocator = .{ .child = std.heap.page_allocator };
    var std_arena: std.heap.ArenaAllocator = .init(counting_std.allocator());
    try Run.run(std_arena.allocator());
    std_arena.deinit();

    var counting: CountingAllocator = .{ .child = std.heap.page_allocator };
    var arena: Arena = .init(counting.allocator(), .{});
    try Run.run(arena.allocator());
    arena.deinit();

    // Not far from the list itself, about 260K, where the std arena keeps
    // every old buffer.
    try std.testing.expect(counting.peak < 350 * 1024);
    try std.testing.expect(counting.peak * 2 < counting_std.peak);
}

test "Arena: lists built and dropped over and over do not keep growing it" {
    var arena: Arena = .init(std.testing.allocator, .{});
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(std.testing.random_seed);
    const random = prng.random();

    var settled: usize = 0;
    for (0..60) |round| {
        var lists: [4]std.ArrayList(u8) = @splat(.empty);
        const len = 1000 + random.uintLessThan(usize, 6000);
        for (0..len) |i| {
            for (&lists) |*l| try l.append(a, @truncate(i));
        }
        for (&lists) |*l| l.deinit(a);
        // The first rounds may not have needed the biggest lists.
        if (round == 10) settled = arena.queryCapacity();
    }
    try std.testing.expect(arena.queryCapacity() <= settled + settled / 2);
}

test "Arena: freed memory is reused by size" {
    var arena: Arena = .init(std.testing.allocator, .{});
    defer arena.deinit();
    const a = arena.allocator();

    const x = try a.alloc(u8, 100);
    _ = try a.alloc(u8, 8);
    a.free(x);
    const y = try a.alloc(u8, 60);
    try std.testing.expectEqual(x.ptr, y.ptr);
    // The rest of it, behind.
    const z = try a.alloc(u8, 30);
    try std.testing.expectEqual(x.ptr + 60, z.ptr);

    var no_lists: Arena = .init(std.testing.allocator, .{ .free_lists = false });
    defer no_lists.deinit();
    const b = no_lists.allocator();
    const p = try b.alloc(u8, 100);
    _ = try b.alloc(u8, 8);
    b.free(p);
    try std.testing.expect((try b.alloc(u8, 60)).ptr != p.ptr);
}

test "Arena: what was freed before a snapshot is not handed out inside it" {
    var arena: Arena = .init(std.testing.allocator, .{});
    defer arena.deinit();
    const a = arena.allocator();

    const x = try a.alloc(u8, 64);
    _ = try a.alloc(u8, 8);
    a.free(x);
    const s = try arena.snapshot();
    const inner = try a.alloc(u8, 64);
    try std.testing.expect(inner.ptr != x.ptr);
    // Freed inside, reused inside.
    _ = try a.alloc(u8, 8);
    a.free(inner);
    try std.testing.expectEqual(inner.ptr, (try a.alloc(u8, 64)).ptr);
    arena.restore(s);
    // Restored, it is still inside the snapshot.
    try std.testing.expect((try a.alloc(u8, 64)).ptr != x.ptr);
    arena.release(s);
    // Released, the one from before is back.
    try std.testing.expectEqual(x.ptr, (try a.alloc(u8, 64)).ptr);
}

test "Arena: reset and trim give chunks back" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    var arena: Arena = .init(counting.allocator(), .{ .min_chunk_size = 1024, .max_chunk_size = 8 * 1024, .large_threshold = 2 * 1024 });
    defer arena.deinit();
    const a = arena.allocator();

    const s = try arena.snapshot();
    for (0..100) |_| _ = try a.alloc(u8, 500);
    const grown = counting.live;
    arena.restore(s);
    try std.testing.expectEqual(grown, counting.live);
    arena.trim(0);
    // Only the chunk the snapshot was taken in is left.
    try std.testing.expect(counting.live <= 1024);

    for (0..100) |_| _ = try a.alloc(u8, 500);
    arena.reset(.{ .retain_with_limit = 4 * 1024 });
    try std.testing.expect(counting.live <= 4 * 1024);
    try std.testing.expect(counting.live > 0);
    arena.reset(.free_all);
    try std.testing.expectEqual(0, counting.live);
    _ = try a.alloc(u8, 10);
}

test "Arena: preheat" {
    var counting: CountingAllocator = .{ .child = std.testing.allocator };
    var arena: Arena = .init(counting.allocator(), .{});
    defer arena.deinit();
    try arena.preheat(8000);
    const allocs = counting.allocs;
    for (0..80) |_| _ = try arena.allocator().alloc(u8, 100);
    try std.testing.expectEqual(allocs, counting.allocs);
}

test "Arena: random allocations, frees, resizes and snapshots never overlap" {
    for (0..32) |i| try fuzz(std.testing.random_seed +% i);
}

fn fuzz(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var arena: Arena = .init(std.testing.allocator, .{
        .min_chunk_size = 512,
        .max_chunk_size = 8 * 1024,
        .large_threshold = 2 * 1024,
        .free_lists = seed % 2 == 0,
        .large_cache_limit = if (seed / 2 % 2 == 0) 64 * 1024 else 0,
    });
    defer arena.deinit();
    const a = arena.allocator();

    const Live = struct { mem: []u8, alignment: Alignment, tag: u8, depth: usize };
    var live: std.ArrayList(Live) = .empty;
    defer live.deinit(std.testing.allocator);
    var snaps: std.ArrayList(Snapshot) = .empty;
    defer snaps.deinit(std.testing.allocator);

    const check = struct {
        fn f(l: Live) !void {
            for (l.mem) |byte| try std.testing.expectEqual(l.tag, byte);
        }
    }.f;

    for (0..10_000) |step| {
        const tag: u8 = @truncate(step);
        switch (random.uintLessThan(u8, 100)) {
            0...44 => {
                const len = if (random.uintLessThan(u8, 20) == 0) random.intRangeAtMost(usize, 1500, 6000) else random.intRangeAtMost(usize, 1, 300);
                const alignment: Alignment = .fromByteUnits(@as(usize, 1) << random.uintAtMost(u6, 6));
                const ptr = a.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;
                try std.testing.expect(alignment.check(@intFromPtr(ptr)));
                const mem = ptr[0..len];
                @memset(mem, tag);
                try live.append(std.testing.allocator, .{ .mem = mem, .alignment = alignment, .tag = tag, .depth = snaps.items.len });
            },
            45...64 => if (live.items.len > 0) {
                const i = random.uintLessThan(usize, live.items.len);
                const l = live.swapRemove(i);
                try check(l);
                a.rawFree(l.mem, l.alignment, @returnAddress());
            },
            65...84 => if (live.items.len > 0) {
                const i = random.uintLessThan(usize, live.items.len);
                const l = &live.items[i];
                try check(l.*);
                const new_len = random.intRangeAtMost(usize, 1, l.mem.len * 2 + 10);
                if (a.rawRemap(l.mem, l.alignment, new_len, @returnAddress())) |ptr| {
                    l.mem = ptr[0..new_len];
                    l.tag = tag;
                    @memset(l.mem, tag);
                }
            },
            85...92 => if (snaps.items.len < 6) {
                try snaps.append(std.testing.allocator, try arena.snapshot());
            },
            else => if (snaps.items.len > 0) {
                // Sometimes an outer one, dropping the inner ones with it.
                const depth = random.uintLessThan(usize, snaps.items.len);
                if (random.boolean()) {
                    arena.restore(snaps.items[depth]);
                    snaps.shrinkRetainingCapacity(depth + 1);
                } else {
                    arena.release(snaps.items[depth]);
                    snaps.shrinkRetainingCapacity(depth);
                }
                var i: usize = 0;
                while (i < live.items.len) {
                    if (live.items[i].depth > depth) _ = live.swapRemove(i) else i += 1;
                }
            },
        }
        // Spot checks, and everything now and then.
        if (live.items.len > 0) try check(live.items[random.uintLessThan(usize, live.items.len)]);
        if (step % 1000 == 0) for (live.items) |l| try check(l);
    }
    for (live.items) |l| try check(l);
}

test "Arena: out of memory" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 3 });
    var arena: Arena = .init(failing.allocator(), .{ .min_chunk_size = 256, .max_chunk_size = 1024, .large_threshold = 512 });
    defer arena.deinit();
    const a = arena.allocator();
    var failed = false;
    for (0..100) |_| {
        _ = a.alloc(u8, 200) catch {
            failed = true;
            break;
        };
    }
    try std.testing.expect(failed);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 2000));
}
