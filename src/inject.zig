const std = @import("std");
const Request = @import("request.zig").Request;
const RequestState = @import("request.zig").RequestState;
const Response = @import("response.zig").Response;

/// Arguments for calling `F`, each filled by its type: `*Ctx`, `*Request`,
/// `*Response`, `*Ctx.RequestState`, and `anyerror` when `err` is one.
pub fn args(
    comptime Ctx: type,
    comptime F: type,
    ctx: if (Ctx == void) void else *Ctx,
    req: *Request,
    res: *Response,
    err: anytype,
) std.meta.ArgsTuple(F) {
    var result: std.meta.ArgsTuple(F) = undefined;
    inline for (0..result.len) |i| result[i] = arg(@TypeOf(result[i]), Ctx, F, ctx, req, res, err);
    return result;
}

fn arg(
    comptime P: type,
    comptime Ctx: type,
    comptime F: type,
    ctx: if (Ctx == void) void else *Ctx,
    req: *Request,
    res: *Response,
    err: anytype,
) P {
    if (comptime pointsTo(P, Request)) return req;
    if (comptime pointsTo(P, Response)) return res;
    if (comptime Ctx != void and pointsTo(P, Ctx)) return ctx;
    if (comptime pointsTo(P, RequestState(Ctx))) return req.state(Ctx);
    if (comptime P == anyerror and @TypeOf(err) == anyerror) return err;
    @compileError("can't inject a parameter of type " ++ @typeName(P) ++ " into " ++ @typeName(F));
}

fn pointsTo(comptime P: type, comptime T: type) bool {
    return P == *T or P == *const T;
}
