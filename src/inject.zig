const std = @import("std");
const Request = @import("request.zig").Request;
const RequestContext = @import("request.zig").RequestContext;
const Response = @import("response.zig").Response;
const extract = @import("extract.zig");

/// What an extractor's `extract` gets.
pub fn Scope(comptime App: type) type {
    return struct {
        app: if (App == void) void else *App,
        req: *Request,
        res: *Response,
        ctx: *RequestContext(App),
    };
}

/// Arguments for calling `F`, each filled by its type: `*App`, `*Request`,
/// `*Response`, `*App.RequestContext`, an extractor, and `anyerror` when
/// `err` is one. An extractor missing its value or failing to parse it is
/// recorded on `req`.
pub fn args(
    comptime App: type,
    comptime F: type,
    app: if (App == void) void else *App,
    req: *Request,
    res: *Response,
    err: anytype,
) !std.meta.ArgsTuple(F) {
    var result: std.meta.ArgsTuple(F) = undefined;
    inline for (0..result.len) |i| {
        const P = @TypeOf(result[i]);
        result[i] = if (comptime P == anyerror and @TypeOf(err) == anyerror) err else try arg(P, App, F, app, req, res);
    }
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
) !P {
    if (comptime pointsTo(P, Request)) return req;
    if (comptime pointsTo(P, Response)) return res;
    if (comptime App != void and pointsTo(P, App)) return app;
    if (comptime pointsTo(P, RequestContext(App))) return req.ctx(App);
    if (comptime extract.isExtractor(P)) {
        const scope: Scope(App) = .{ .app = app, .req = req, .res = res, .ctx = req.ctx(App) };
        const result = P.extract(scope);
        if (@typeInfo(@TypeOf(result)) != .error_union) return result;
        return result catch |e| {
            if (e == error.MissingValue or e == error.InvalidValue) req._extract_failed = true;
            return e;
        };
    }
    @compileError("can't inject a parameter of type " ++ @typeName(P) ++ " into " ++ @typeName(F));
}

fn pointsTo(comptime P: type, comptime T: type) bool {
    return P == *T or P == *const T;
}

/// The `Param` types among `F`'s parameters.
pub fn params(comptime F: type) []const type {
    comptime {
        const a: std.meta.ArgsTuple(F) = undefined;
        var result: []const type = &.{};
        for (0..a.len) |i| {
            if (extract.isParam(@TypeOf(a[i]))) result = result ++ .{@TypeOf(a[i])};
        }
        return result;
    }
}

/// A compile error if `F` takes a `Param`, for functions that are not
/// called for a route.
pub fn noParams(comptime F: type, comptime name: []const u8) void {
    const found = params(F);
    if (found.len > 0) @compileError(name ++ " can't take dusty.Param(\"" ++ found[0].param_name ++ "\", ...): it isn't called for a route");
}

/// A compile error if `F` takes an extractor, for functions that can't
/// fail.
pub fn noExtractors(comptime F: type, comptime name: []const u8) void {
    const a: std.meta.ArgsTuple(F) = undefined;
    inline for (0..a.len) |i| {
        if (extract.isExtractor(@TypeOf(a[i]))) @compileError(name ++ " can't take " ++ @typeName(@TypeOf(a[i])) ++ ": it can't fail");
    }
}
