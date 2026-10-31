const std = @import("std");
const Request = @import("request.zig").Request;

/// A path parameter of the route, parsed as `T`, for a handler to take as
/// an argument:
///
///     fn getUser(id: dusty.Param("id", u64), res: *dusty.Response) !void
///
/// The route path must have `:name` or `*name`, which is checked at compile
/// time. A value that does not parse as `T` makes the route not match, so
/// the router tries the others and answers 404 if none does.
///
/// `T` is an integer (decimal digits with no leading zero, and a leading
/// `-` if signed), an
/// enum (a tag name), `bool` (`true` or `false`), `[]const u8` (as it
/// is), or a type declaring `pub fn parseParam([]const u8) ?T`.
pub fn Param(comptime name: []const u8, comptime T: type) type {
    comptime checkType(T);
    return struct {
        value: T,

        pub const param_name = name;
        pub const Value = T;

        /// Only called for a route the router matched, which it does only
        /// once the value has parsed.
        pub fn fromRequest(req: *const Request) @This() {
            const raw = req.params.get(name) orelse unreachable;
            return .{ .value = parse(T, raw) orelse unreachable };
        }

        pub fn accepts(req: *const Request) bool {
            const raw = req.params.get(name) orelse return false;
            return parse(T, raw) != null;
        }
    };
}

/// Whether `P` is a `Param`.
pub fn isParam(comptime P: type) bool {
    return @typeInfo(P) == .@"struct" and @hasDecl(P, "param_name") and @hasDecl(P, "Value") and P == Param(P.param_name, P.Value);
}

fn checkType(comptime T: type) void {
    if (T == []const u8) return;
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "parseParam")) {
            if (@TypeOf(T.parseParam) != fn ([]const u8) ?T) @compileError(@typeName(T) ++ ".parseParam must be `fn ([]const u8) ?" ++ @typeName(T) ++ "`");
            return;
        },
        else => {},
    }
    switch (@typeInfo(T)) {
        .int, .@"enum", .bool => {},
        else => @compileError("dusty.Param can't parse " ++ @typeName(T) ++ "; give it a `pub fn parseParam([]const u8) ?" ++ @typeName(T) ++ "`"),
    }
}

pub fn parse(comptime T: type, raw: []const u8) ?T {
    if (T == []const u8) return raw;
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "parseParam")) return T.parseParam(raw),
        else => {},
    }
    switch (@typeInfo(T)) {
        .int => |info| {
            // `parseInt` also takes `+`, `_`, a base prefix and leading
            // zeros, which would give one value many URLs.
            const negative = info.signedness == .signed and raw.len > 0 and raw[0] == '-';
            const digits = if (negative) raw[1..] else raw;
            if (digits.len == 0) return null;
            if (digits[0] == '0' and (digits.len > 1 or negative)) return null;
            for (digits) |c| if (!std.ascii.isDigit(c)) return null;
            return std.fmt.parseInt(T, raw, 10) catch null;
        },
        .@"enum" => return std.meta.stringToEnum(T, raw),
        .bool => {
            if (std.mem.eql(u8, raw, "true")) return true;
            if (std.mem.eql(u8, raw, "false")) return false;
            return null;
        },
        else => comptime unreachable,
    }
}

test "parse: integers take plain decimal digits only" {
    try std.testing.expectEqual(@as(?u32, 42), parse(u32, "42"));
    try std.testing.expectEqual(@as(?i32, -7), parse(i32, "-7"));
    try std.testing.expectEqual(@as(?u32, null), parse(u32, "-7"));
    try std.testing.expectEqual(@as(?u32, null), parse(u32, "+7"));
    try std.testing.expectEqual(@as(?u32, null), parse(u32, "1_000"));
    try std.testing.expectEqual(@as(?u32, null), parse(u32, "0x10"));
    try std.testing.expectEqual(@as(?u32, null), parse(u32, ""));
    try std.testing.expectEqual(@as(?u8, null), parse(u8, "256"));
    try std.testing.expectEqual(@as(?u32, 0), parse(u32, "0"));
    try std.testing.expectEqual(@as(?u32, null), parse(u32, "007"));
    try std.testing.expectEqual(@as(?i32, null), parse(i32, "-0"));
}

test "parse: enums, bools and custom types" {
    const Lang = enum { en, de };
    try std.testing.expectEqual(@as(?Lang, .de), parse(Lang, "de"));
    try std.testing.expectEqual(@as(?Lang, null), parse(Lang, "fr"));
    try std.testing.expectEqual(@as(?bool, true), parse(bool, "true"));
    try std.testing.expectEqual(@as(?bool, null), parse(bool, "1"));

    const Even = struct {
        n: u32,
        pub fn parseParam(raw: []const u8) ?@This() {
            const n = parse(u32, raw) orelse return null;
            return if (n % 2 == 0) .{ .n = n } else null;
        }
    };
    try std.testing.expectEqual(@as(u32, 4), parse(Even, "4").?.n);
    try std.testing.expect(parse(Even, "5") == null);
}
