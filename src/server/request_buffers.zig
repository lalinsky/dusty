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
    node: std.SinglyLinkedList.Node = .{},
};

pub const RequestBuffersPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    read_buffer_len: usize,
    /// Primed into each arena, so an ordinary request is served without
    /// growing it.
    arena_reserve: usize,
    mutex: std.Io.Mutex = .init,
    free: std.SinglyLinkedList = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, read_buffer_len: usize, arena_reserve: usize) RequestBuffersPool {
        return .{
            .allocator = allocator,
            .io = io,
            .read_buffer_len = read_buffer_len,
            .arena_reserve = arena_reserve,
        };
    }

    /// Only once every set is back.
    pub fn deinit(self: *RequestBuffersPool) void {
        while (self.free.popFirst()) |node| self.destroy(@fieldParentPtr("node", node));
        self.* = undefined;
    }

    /// A free set, or a new one if none is.
    pub fn acquire(self: *RequestBuffersPool) std.mem.Allocator.Error!*RequestBuffers {
        const node = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.free.popFirst();
        };
        if (node) |n| return @fieldParentPtr("node", n);
        return self.create();
    }

    /// Gives a set back, its arena reset.
    pub fn release(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        _ = buffers.arena.reset(.retain_capacity);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.free.prepend(&buffers.node);
    }

    fn create(self: *RequestBuffersPool) std.mem.Allocator.Error!*RequestBuffers {
        const size = std.math.add(usize, @sizeOf(RequestBuffers), self.read_buffer_len) catch return error.OutOfMemory;
        const memory = try self.allocator.alignedAlloc(u8, .of(RequestBuffers), size);
        const buffers: *RequestBuffers = @ptrCast(memory.ptr);
        buffers.* = .{
            .arena = .init(self.allocator),
            .read_buffer = memory[@sizeOf(RequestBuffers)..],
        };
        errdefer self.destroy(buffers);
        // Reset keeps the memory, as one node the requests are then carved
        // from.
        _ = try buffers.arena.allocator().alloc(u8, self.arena_reserve);
        _ = buffers.arena.reset(.retain_capacity);
        return buffers;
    }

    fn destroy(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        buffers.arena.deinit();
        const base: [*]align(@alignOf(RequestBuffers)) u8 = @ptrCast(buffers);
        self.allocator.free(base[0 .. @sizeOf(RequestBuffers) + self.read_buffer_len]);
    }
};

test "RequestBuffersPool: a set given back is the next one taken" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 256);
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
