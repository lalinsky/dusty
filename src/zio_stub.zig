// Stub `zio` module: provides the minimal API surface dusty needs to compile
// and run without depending on the real zio package. Downstream apps using the
// zio runtime override this import so timeouts use zio.AutoCancel rather than
// dusty's portable watchdog:
//
//     const zio_dep = b.dependency("zio", .{});
//     const dusty_mod = b.dependency("dusty", .{}).module("dusty");
//     dusty_mod.addImport("zio", zio_dep.module("zio"));

const std = @import("std");

/// dusty checks for this to select its watchdog path over `AutoCancel`.
pub const is_stub = true;

pub const Timeout = struct {
    pub fn fromStd(_: std.Io.Timeout) Timeout {
        return .{};
    }
};

pub const Clock = struct {
    pub fn fromStdTimeout(_: std.Io.Timeout) Clock {
        return .{};
    }
};

pub const AutoCancel = struct {
    pub const init: AutoCancel = .{};

    /// Never armed: `is_stub` selects the watchdog path.
    pub fn setClock(_: *AutoCancel, _: Timeout, _: Clock) void {
        unreachable;
    }

    pub fn clear(_: *AutoCancel) void {}
};
