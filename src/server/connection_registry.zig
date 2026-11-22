//! The connections a server is running. Each connection's entry lives on
//! its own task's stack, and is linked in for as long as the task runs, so
//! nothing here is allocated or locked per request. The lists are sharded
//! so that connections opening and closing at once mostly take different
//! locks.

const std = @import("std");

pub const ConnectionEntry = struct {
    node: std.DoublyLinkedList.Node = .{},
    /// Written by the connection's own task, and read by the drain.
    state: std.atomic.Value(State) = .init(.busy),
    /// The shard it is linked into.
    shard: u8 = 0,

    pub const State = enum(u8) {
        /// Handshaking, or serving a request.
        busy,
        /// Waiting for the next request.
        idle,
    };
};

pub const ConnectionRegistry = struct {
    io: std.Io,
    shards: [shard_count]Shard = @splat(.{}),

    const shard_count = 16;

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        list: std.DoublyLinkedList = .{},
        // Each shard's lock on its own cache line.
        _: void align(std.atomic.cache_line) = {},
    };

    pub fn init(io: std.Io) ConnectionRegistry {
        return .{ .io = io };
    }

    /// The entry must stay where it is until `unlink`.
    pub fn link(self: *ConnectionRegistry, entry: *ConnectionEntry) void {
        const index: u8 = @intCast(std.hash.int(@intFromPtr(entry)) % shard_count);
        entry.shard = index;
        const shard = &self.shards[index];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        shard.list.append(&entry.node);
    }

    pub fn unlink(self: *ConnectionRegistry, entry: *ConnectionEntry) void {
        const shard = &self.shards[entry.shard];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        shard.list.remove(&entry.node);
    }

    pub fn countBusy(self: *ConnectionRegistry) usize {
        var count: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(self.io);
            defer shard.mutex.unlock(self.io);
            var it = shard.list.first;
            while (it) |node| : (it = node.next) {
                const entry: *ConnectionEntry = @fieldParentPtr("node", node);
                if (entry.state.load(.seq_cst) == .busy) count += 1;
            }
        }
        return count;
    }
};

test "ConnectionRegistry: counts the busy entries across shards" {
    var registry: ConnectionRegistry = .init(std.testing.io);
    var entries: [40]ConnectionEntry = @splat(.{});
    for (&entries) |*e| registry.link(e);
    try std.testing.expectEqual(40, registry.countBusy());

    for (entries[0..25]) |*e| e.state.store(.idle, .release);
    try std.testing.expectEqual(15, registry.countBusy());

    for (entries[30..]) |*e| registry.unlink(e);
    try std.testing.expectEqual(5, registry.countBusy());

    for (entries[0..30]) |*e| registry.unlink(e);
    try std.testing.expectEqual(0, registry.countBusy());
}
