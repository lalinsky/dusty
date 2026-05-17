// Stub `zio` module: provides the minimal API surface dusty needs to compile
// and run without depending on the real zio package. Downstream apps that want
// real timeouts override this import in their build.zig:
//
//     const zio_dep = b.dependency("zio", .{});
//     const dusty_mod = b.dependency("dusty", .{}).module("dusty");
//     dusty_mod.addImport("zio", zio_dep.module("zio"));

pub const Duration = struct {
    pub fn fromMilliseconds(_: i64) Duration {
        return .{};
    }
};

pub const AutoCancel = struct {
    pub const init: AutoCancel = .{};

    pub fn set(_: *AutoCancel, _: Duration) void {
        @panic("dusty: timeout configured but no `zio` module injected; override in build.zig via `dusty_mod.addImport(\"zio\", zio_dep.module(\"zio\"))`");
    }

    pub fn clear(_: *AutoCancel) void {}
};
