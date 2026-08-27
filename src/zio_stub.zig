// Stub `zio` module: provides the minimal API surface dusty needs to compile
// and run without depending on the real zio package. Downstream apps using the
// zio runtime override this import so timeouts use zio.AutoCancel rather than
// dusty's portable watchdog:
//
//     const zio_dep = b.dependency("zio", .{});
//     const dusty_mod = b.dependency("dusty", .{}).module("dusty");
//     dusty_mod.addImport("zio", zio_dep.module("zio"));

pub const Duration = struct {
    pub fn fromMilliseconds(_: i64) Duration {
        return .{};
    }
};

/// dusty checks for this to select its watchdog path over `AutoCancel`.
pub const is_stub = true;

pub const AutoCancel = struct {
    pub const init: AutoCancel = .{};

    /// Never armed: `is_stub` selects the watchdog path.
    pub fn set(_: *AutoCancel, _: Duration) void {
        unreachable;
    }

    pub fn clear(_: *AutoCancel) void {}
};
