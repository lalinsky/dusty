const std = @import("std");
const zio = @import("zio");

/// Whether the injected `zio` can arm a timer against the running task. The
/// stub says so by declaring `is_stub`; the real package does not.
pub const have_auto_cancel = !@hasDecl(zio, "is_stub");

/// A deadline one task publishes and another waits on.
///
/// The watcher sleeps on `generation`, which every re-arm and the finish bump
/// before waking it. That order is what makes the wait lossless: a re-arm
/// racing the watcher leaves the word different from what the wait expects,
/// so it returns rather than sleeping on stale terms.
pub const Watch = struct {
    generation: std.atomic.Value(u32) = .init(0),
    mutex: std.Io.Mutex = .init,
    /// Guarded by `mutex`. Never `.duration`: `set` pins one to the moment it
    /// was published.
    timeout: std.Io.Timeout = .none,
    /// Guarded by `mutex`.
    finished: bool = false,

    const State = struct {
        timeout: std.Io.Timeout,
        finished: bool,
    };

    fn wake(self: *Watch, io: std.Io) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
        io.futexWake(u32, &self.generation.raw, 1);
    }

    fn published(self: *Watch, io: std.Io) State {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{ .timeout = self.timeout, .finished = self.finished };
    }

    pub fn set(self: *Watch, io: std.Io, timeout: std.Io.Timeout) void {
        // A duration runs from the call that published it, and the watcher may
        // not read it until much later.
        const deadline = timeout.toDeadline(io);
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.timeout = deadline;
        }
        self.wake(io);
    }

    pub fn arm(self: *Watch, io: std.Io, duration: std.Io.Duration) void {
        self.set(io, .{ .duration = .{ .raw = duration, .clock = .awake } });
    }

    pub fn disarm(self: *Watch, io: std.Io) void {
        self.set(io, .none);
    }

    pub fn finish(self: *Watch, io: std.Io) void {
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.finished = true;
        }
        self.wake(io);
    }

    /// Blocks until the watched work finishes, or `error.Timeout` if it
    /// overruns the deadline it last published.
    pub fn wait(self: *Watch, io: std.Io) (std.Io.Cancelable || std.Io.Timeout.Error)!void {
        while (true) {
            // Captured before the snapshot, so a `set` that lands in between
            // is one the wait below refuses to sleep through.
            const generation = self.generation.load(.acquire);
            const state = self.published(io);
            if (state.finished) return;

            // The wait does not report why it returned, and `generation` is
            // only its wakeup token: `set` publishes the deadline before the
            // bump, so an unchanged generation does not mean an unchanged
            // deadline. Every wakeup comes back here and judges the deadline
            // published now, never the one it went to sleep on.
            if (state.timeout.toTimestamp(io)) |deadline| {
                if (std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.gte, deadline)) {
                    return error.Timeout;
                }
            }

            try io.futexWaitTimeout(u32, &self.generation.raw, generation, state.timeout);
        }
    }
};

/// Bounds how long the running task may spend on any one blocking step.
///
/// zio arms a timer against the running task. `std.Io` has no deadline for a
/// stream read, only cancelation, so elsewhere the deadline goes to a second
/// task that cancels this one when it passes.
pub const Timer = if (have_auto_cancel) struct {
    inner: zio.AutoCancel = .init,

    pub fn init(_: ?*Watch) @This() {
        return .{};
    }

    pub fn set(self: *@This(), _: std.Io, timeout: std.Io.Timeout) void {
        // `Timeout.fromStd` keeps the value clockless and `Clock.fromStdTimeout`
        // carries the clock, which is how zio wants the two halves.
        self.inner.setClock(.fromStd(timeout), .fromStdTimeout(timeout));
    }

    pub fn clear(self: *@This(), _: std.Io) void {
        self.inner.clear();
    }

    pub fn canBound(_: *const @This()) bool {
        return true;
    }
} else struct {
    /// Null when no deadline was configured.
    watch: ?*Watch = null,

    pub fn init(w: ?*Watch) @This() {
        return .{ .watch = w };
    }

    pub fn set(self: *@This(), io: std.Io, timeout: std.Io.Timeout) void {
        const w = self.watch orelse return;
        w.set(io, timeout);
    }

    pub fn clear(self: *@This(), io: std.Io) void {
        const w = self.watch orelse return;
        w.disarm(io);
    }

    /// Whether `set` does anything: there is no watcher when no deadline
    /// was configured for the connection.
    pub fn canBound(self: *const @This()) bool {
        return self.watch != null;
    }
};

/// A moment past which a call is not allowed to run, carried between the
/// calls it bounds. Each of them arms it on entry and clears it before
/// returning, so a cancel can only ever arrive inside one of them, never in
/// whatever the caller does in between.
///
/// A budget shared by several calls, such as a request and the reads of its
/// body, is one deadline pinned once by `init` and run as many times as
/// there are calls.
pub const Deadline = struct {
    io: std.Io,
    /// Absolute, or `.none`: `init` pins a duration to the moment it was
    /// given.
    timeout: std.Io.Timeout,

    /// What `run` can fail with beyond what it ran.
    pub const Error = error{Timeout} || std.Io.Cancelable ||
        (if (have_auto_cancel) error{} else std.Io.ConcurrentError);

    /// The return type of `run(func, args)`: whatever `func` returns, with
    /// `Error` added to its error set.
    pub fn Result(comptime func: anytype) type {
        const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        return switch (@typeInfo(Ret)) {
            .error_union => |eu| (eu.error_set || Error)!eu.payload,
            else => Error!Ret,
        };
    }

    pub fn init(io: std.Io, timeout: std.Io.Timeout) Deadline {
        return .{ .io = io, .timeout = timeout.toDeadline(io) };
    }

    /// Runs `func(args...)` under the deadline. A call that ran past it
    /// fails with `error.Timeout`, unless it managed to finish regardless,
    /// in which case its own result stands. A cancel of the calling task
    /// wins over the deadline and comes back as `error.Canceled`.
    pub fn run(self: Deadline, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(func) {
        if (self.timeout == .none) return @call(.auto, func, args);
        if (comptime have_auto_cancel) return self.runAutoCanceled(func, args);
        return self.runWatched(func, args);
    }

    fn runAutoCanceled(self: Deadline, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(func) {
        var auto: zio.AutoCancel = .init;
        auto.setClock(.fromStd(self.timeout), .fromStdTimeout(self.timeout));
        const ret = @call(.auto, func, args);
        auto.clear();

        // The cancel may not come out as `error.Canceled`: a reader records
        // it and reports the generic `ReadFailed` its interface allows. Any
        // failure after the timer fired is the timer's doing.
        //
        // A timer that fires after the call's last cancelation point leaves
        // the cancel pending for the caller's next one, which is zio's own
        // `withTimeout` contract too.
        return ret catch |err| {
            if (auto.check(error.Canceled)) return error.Timeout;
            return err;
        };
    }

    /// The deadline goes to this task, which sleeps on a `Watch`, and the
    /// call to a second one that the wait cancels when the deadline passes.
    fn runWatched(self: Deadline, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(func) {
        const Args = @TypeOf(args);
        const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Runner = struct {
            fn run(watch: *Watch, io: std.Io, a: Args) Ret {
                defer watch.finish(io);
                return @call(.auto, func, a);
            }
        };

        var watch: Watch = .{};
        watch.set(self.io, self.timeout);
        var future = try self.io.concurrent(Runner.run, .{ &watch, self.io, args });

        watch.wait(self.io) catch |err| switch (err) {
            // The call may have finished in the window between the deadline
            // passing and the cancel reaching it. Its result then stands; a
            // failure in that window is reported as the timeout it ran into.
            error.Timeout => return future.cancel(self.io) catch return error.Timeout,
            error.Canceled => {
                const ret = future.cancel(self.io) catch return error.Canceled;
                // Finished anyway. The wait consumed the cancel, so it is
                // raised again for the caller's next cancelation point.
                self.io.recancel();
                return ret;
            },
        };

        return future.await(self.io);
    }
};

test "Watch: accepts an absolute deadline on another clock" {
    const io = std.testing.io;
    var watch: Watch = .{};
    const deadline = std.Io.Clock.Timestamp.now(io, .real).addDuration(.{
        .raw = .fromMilliseconds(50),
        .clock = .real,
    });
    watch.set(io, .{ .deadline = deadline });
    try std.testing.expectError(error.Timeout, watch.wait(io));
}

test "Watch: a deadline republished before its generation does not expire the connection" {
    const io = std.testing.io;
    var watch: Watch = .{};

    // Leave enough room for the watcher and this test task both to be
    // scheduled on a loaded runner before the first deadline arrives.
    watch.arm(io, .fromMilliseconds(500));

    var watcher = try io.concurrent(struct {
        fn go(w: *Watch, i: std.Io) (std.Io.Cancelable || std.Io.Timeout.Error)!void {
            return w.wait(i);
        }
    }.go, .{ &watch, io });
    defer watcher.cancel(io) catch {};

    // The watcher is now asleep holding the first deadline. Publish a later
    // one the way `arm` does, but stop short of the generation bump -- the
    // window between its store and its wake.
    try io.sleep(.fromMilliseconds(25), .awake);
    const later: std.Io.Timeout = .{
        .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(5_000), .clock = .awake }),
    };
    watch.mutex.lockUncancelable(io);
    watch.timeout = later;
    watch.mutex.unlock(io);

    // Well past the first deadline, and nowhere near the second.
    try io.sleep(.fromMilliseconds(600), .awake);
    watch.finish(io);

    try watcher.await(io);
}

test "Deadline.run: a call that overruns fails with Timeout" {
    const io = std.testing.io;
    const deadline: Deadline = .init(io, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } });
    const result = deadline.run(struct {
        fn slow(i: std.Io) std.Io.Cancelable!u8 {
            try i.sleep(.fromMilliseconds(5_000), .awake);
            return 1;
        }
    }.slow, .{io});
    try std.testing.expectError(error.Timeout, result);
}

test "Deadline.run: a call that finishes in time keeps its own result" {
    const io = std.testing.io;
    const deadline: Deadline = .init(io, .{ .duration = .{ .raw = .fromMilliseconds(5_000), .clock = .awake } });
    const Fast = struct {
        fn ok(i: std.Io) std.Io.Cancelable!u8 {
            try i.sleep(.fromMilliseconds(1), .awake);
            return 7;
        }
        fn failing(_: std.Io) error{ Canceled, Boom }!u8 {
            return error.Boom;
        }
    };
    try std.testing.expectEqual(7, try deadline.run(Fast.ok, .{io}));
    try std.testing.expectError(error.Boom, deadline.run(Fast.failing, .{io}));
}

test "Deadline.run: no deadline runs the call in place" {
    const io = std.testing.io;
    const deadline: Deadline = .init(io, .none);
    try std.testing.expectEqual(3, try deadline.run(struct {
        fn f() error{Canceled}!u8 {
            return 3;
        }
    }.f, .{}));
}
