const std = @import("std");
const Request = @import("request.zig").Request;
const RequestContext = @import("request.zig").RequestContext;
const Response = @import("response.zig").Response;

/// Arguments for calling `F`, each filled by its type: `*App`, `*Request`,
/// `*Response`, `*App.RequestContext`, and `anyerror` when `err` is one.
pub fn args(
    comptime App: type,
    comptime F: type,
    app: if (App == void) void else *App,
    req: *Request,
    res: *Response,
    err: anytype,
) std.meta.ArgsTuple(F) {
    var result: std.meta.ArgsTuple(F) = undefined;
    inline for (0..result.len) |i| result[i] = arg(@TypeOf(result[i]), App, F, app, req, res, err);
    return result;
}

/// Whether `F` returns `!void`; a compile error unless it returns that or
/// `void`, or only `void` when `fallible` is false.
pub fn returnsError(comptime F: type, comptime name: []const u8, comptime fallible: bool) bool {
    if (@typeInfo(F) != .@"fn") @compileError("expected a function for " ++ name ++ ", found " ++ @typeName(F));
    const R = @typeInfo(F).@"fn".return_type orelse @compileError(name ++ " has a generic return type");
    if (R == void) return false;
    if (fallible and @typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == void) return true;
    @compileError(name ++ " must return " ++ (if (fallible) "void or !void" else "void"));
}

fn arg(
    comptime P: type,
    comptime App: type,
    comptime F: type,
    app: if (App == void) void else *App,
    req: *Request,
    res: *Response,
    err: anytype,
) P {
    if (comptime pointsTo(P, Request)) return req;
    if (comptime pointsTo(P, Response)) return res;
    if (comptime App != void and pointsTo(P, App)) return app;
    if (comptime pointsTo(P, RequestContext(App))) return req.ctx(App);
    if (comptime P == anyerror and @TypeOf(err) == anyerror) return err;
    @compileError("can't inject a parameter of type " ++ @typeName(P) ++ " into " ++ @typeName(F));
}

fn pointsTo(comptime P: type, comptime T: type) bool {
    return P == *T or P == *const T;
}
