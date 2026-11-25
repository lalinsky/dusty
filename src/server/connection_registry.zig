//! The connections a server is running. Each connection's entry lives on
//! its own task's stack, and is linked in for as long as the task runs, so
//! nothing here is allocated or locked per request, and a request touches
//! no memory shared with other connections. The lists are sharded so that
//! connections opening and closing at once mostly take different locks.

const std = @import("std");

pub const ConnectionEntry = struct {
    node: std.DoublyLinkedList.Node = .{},
    /// Written by the connection's own task only.
    state: std.atomic.Value(State) = .init(.busy),
    /// Written by the registry only, and never cleared.
    ///
    /// A connection marks itself busy and then reads this, the registry
    /// sets this and then reads the state, all sequentially consistent, so
    /// at least one of them sees the other: a request is either refused by
    /// the connection or seen in flight by the registry.
    closing: std.atomic.Value(bool) = .init(false),
    /// The shard it is linked into.
    shard: u8 = 0,
    /// Which of the shard's lists it is on. Guarded by the shard's lock.
    pending: bool = false,

    pub const State = enum(u8) {
        /// Handshaking, or serving a request.
        busy,
        /// Waiting for the next request.
        idle,
    };

    /// The connection is waiting for a request, and has nothing in flight.
    pub fn setIdle(self: *ConnectionEntry) void {
        self.state.store(.idle, .release);
    }

    /// A request arrived. False when the registry is closing, and the
    /// request has to be refused: the entry is idle again, and nobody waits
    /// for it.
    pub fn setBusy(self: *ConnectionEntry) bool {
        // See `closing`.
        self.state.store(.busy, .seq_cst);
        if (self.closing.load(.seq_cst)) {
            self.state.store(.idle, .release);
            return false;
        }
        return true;
    }

    /// Whether the connection should end after what it has in flight.
    ///
    /// May still read false just after `close`. A connection that goes idle
    /// on that reading does not `settle`, and stays pending until the next
    /// `countPending`, with nothing to tell whoever waits on the count. So
    /// the count has to be taken again after a while, even unprompted.
    pub fn isClosing(self: *const ConnectionEntry) bool {
        return self.closing.load(.monotonic);
    }
};

pub const ConnectionRegistry = struct {
    io: std.Io,
    shards: [shard_count]Shard = @splat(.{}),

    const shard_count = 16;

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        list: std.DoublyLinkedList = .{},
        /// The entries `close` found busy and `countPending` has not seen
        /// idle since, and the ones linked after `close`.
        pending: std.DoublyLinkedList = .{},
        closing: bool = false,
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
        entry.closing.store(shard.closing, .monotonic);
        entry.pending = shard.closing;
        if (entry.pending) shard.pending.append(&entry.node) else shard.list.append(&entry.node);
    }

    /// True when it was the last pending connection of its shard, which is
    /// when `countPending` is worth calling again.
    pub fn unlink(self: *ConnectionRegistry, entry: *ConnectionEntry) bool {
        const shard = &self.shards[entry.shard];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        if (!entry.pending) {
            shard.list.remove(&entry.node);
            return false;
        }
        shard.pending.remove(&entry.node);
        return shard.pending.first == null;
    }

    /// For a closing connection that has gone idle: it is no longer
    /// pending. Returns what `unlink` does.
    pub fn settle(self: *ConnectionRegistry, entry: *ConnectionEntry) bool {
        const shard = &self.shards[entry.shard];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        if (!entry.pending) return false;
        shard.pending.remove(&entry.node);
        shard.list.append(&entry.node);
        entry.pending = false;
        return shard.pending.first == null;
    }

    /// Marks every connection as closing, the ones linked later included.
    /// From here on `setBusy` fails for a connection that was idle, and the
    /// busy ones are pending until they go idle or are unlinked.
    pub fn close(self: *ConnectionRegistry) void {
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(self.io);
            defer shard.mutex.unlock(self.io);
            if (shard.closing) continue;
            shard.closing = true;
            var it = shard.list.first;
            while (it) |node| {
                it = node.next;
                const entry: *ConnectionEntry = @fieldParentPtr("node", node);
                // See `ConnectionEntry.closing`.
                entry.closing.store(true, .seq_cst);
                if (entry.state.load(.seq_cst) == .idle) continue;
                shard.list.remove(node);
                shard.pending.append(node);
                entry.pending = true;
            }
        }
    }

    /// Whether `close` has finished.
    pub fn isClosed(self: *ConnectionRegistry) bool {
        // The last one `close` gets to.
        const shard = &self.shards[shard_count - 1];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        return shard.closing;
    }

    /// How many connections still have something in flight, after `close`.
    ///
    /// Only walks the ones that had at the last call. A closing connection
    /// that has been seen idle never has anything in flight again, so it is
    /// dropped from the pending ones for good, as if it had called `settle`.
    pub fn countPending(self: *ConnectionRegistry) usize {
        var count: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(self.io);
            defer shard.mutex.unlock(self.io);
            var it = shard.pending.first;
            while (it) |node| {
                it = node.next;
                const entry: *ConnectionEntry = @fieldParentPtr("node", node);
                if (entry.state.load(.seq_cst) == .busy) {
                    count += 1;
                    continue;
                }
                shard.pending.remove(node);
                shard.list.append(node);
                entry.pending = false;
            }
        }
        return count;
    }
};

fn expectEmpty(registry: *ConnectionRegistry) !void {
    for (&registry.shards) |*shard| {
        try std.testing.expectEqual(null, shard.list.first);
        try std.testing.expectEqual(null, shard.pending.first);
    }
}

fn countTrue(results: []const bool) usize {
    return std.mem.count(bool, results, &.{true});
}

test "ConnectionRegistry: nothing is closing or pending before close" {
    var registry: ConnectionRegistry = .init(std.testing.io);
    var entries: [40]ConnectionEntry = @splat(.{});
    for (&entries) |*e| registry.link(e);

    try std.testing.expect(!registry.isClosed());
    try std.testing.expectEqual(0, registry.countPending());
    for (&entries) |*e| {
        try std.testing.expect(!e.isClosing());
        e.setIdle();
        try std.testing.expect(e.setBusy());
    }

    for (&entries) |*e| try std.testing.expect(!registry.unlink(e));
    try expectEmpty(&registry);
}

test "ConnectionRegistry: close leaves the busy connections pending until they go idle or unlink" {
    var registry: ConnectionRegistry = .init(std.testing.io);
    var entries: [40]ConnectionEntry = @splat(.{});
    for (&entries) |*e| registry.link(e);
    for (entries[0..25]) |*e| e.setIdle();

    registry.close();
    try std.testing.expect(registry.isClosed());
    for (&entries) |*e| try std.testing.expect(e.isClosing());
    try std.testing.expectEqual(15, registry.countPending());

    for (entries[25..30]) |*e| {
        e.setIdle();
        _ = registry.settle(e);
    }
    try std.testing.expectEqual(10, registry.countPending());

    // Idle, but it missed the mark and did not settle.
    entries[30].setIdle();
    try std.testing.expectEqual(9, registry.countPending());

    for (entries[31..35]) |*e| _ = registry.unlink(e);
    try std.testing.expectEqual(5, registry.countPending());

    // Idle ones, from before the close and after it.
    for (entries[0..31]) |*e| try std.testing.expect(!registry.unlink(e));
    try std.testing.expectEqual(5, registry.countPending());

    for (entries[35..]) |*e| _ = registry.unlink(e);
    try std.testing.expectEqual(0, registry.countPending());
    try expectEmpty(&registry);
}

test "ConnectionRegistry: the last pending connection of each shard is reported, and only that" {
    var registry: ConnectionRegistry = .init(std.testing.io);
    var entries: [40]ConnectionEntry = @splat(.{});
    for (&entries) |*e| registry.link(e);
    registry.close();

    var used: [ConnectionRegistry.shard_count]bool = @splat(false);
    for (&entries) |*e| used[e.shard] = true;

    // Half of them go idle, the rest unlink while pending.
    var results: [40]bool = undefined;
    for (&entries, &results, 0..) |*e, *result, i| {
        if (i % 2 == 0) {
            e.setIdle();
            result.* = registry.settle(e);
        } else {
            result.* = registry.unlink(e);
        }
    }
    try std.testing.expectEqual(countTrue(&used), countTrue(&results));
    try std.testing.expectEqual(0, registry.countPending());

    for (&entries, 0..) |*e, i| {
        if (i % 2 != 0) continue;
        try std.testing.expect(!registry.settle(e));
        try std.testing.expect(!registry.unlink(e));
    }
    try expectEmpty(&registry);
}

test "ConnectionRegistry: a closing connection that was idle refuses its next request" {
    var registry: ConnectionRegistry = .init(std.testing.io);
    var entries: [40]ConnectionEntry = @splat(.{});
    for (&entries) |*e| {
        registry.link(e);
        e.setIdle();
    }

    registry.close();
    try std.testing.expectEqual(0, registry.countPending());
    for (&entries) |*e| {
        try std.testing.expect(!e.setBusy());
        try std.testing.expectEqual(.idle, e.state.load(.monotonic));
        try std.testing.expect(!registry.settle(e));
    }
    try std.testing.expectEqual(0, registry.countPending());

    for (&entries) |*e| try std.testing.expect(!registry.unlink(e));
    try expectEmpty(&registry);
}

test "ConnectionRegistry: a connection linked after close is closing and pending" {
    var registry: ConnectionRegistry = .init(std.testing.io);
    registry.close();

    var entries: [40]ConnectionEntry = @splat(.{});
    for (&entries) |*e| registry.link(e);
    for (&entries) |*e| try std.testing.expect(e.isClosing());
    try std.testing.expectEqual(40, registry.countPending());

    for (entries[0..20]) |*e| {
        e.setIdle();
        _ = registry.settle(e);
    }
    try std.testing.expectEqual(20, registry.countPending());
    for (entries[0..20]) |*e| try std.testing.expect(!e.setBusy());

    for (&entries) |*e| _ = registry.unlink(e);
    try std.testing.expectEqual(0, registry.countPending());
    try expectEmpty(&registry);
}
