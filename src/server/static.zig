const std = @import("std");
const builtin = @import("builtin");
const http = @import("../http.zig");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub const StaticOptions = struct {
    /// Served for a request that names a directory. `null` answers it with
    /// a 404 instead.
    index: ?[]const u8 = "index.html",
    /// Encodings to look for compressed copies in, in order of preference:
    /// `style.css.br` is served for `style.css` to a client that accepts
    /// br, with the type of `style.css`. The plain file has to exist too.
    precompressed: []const Precompressed = &.{},
    /// Answer a path with a segment that starts with `.`, such as `/.env`
    /// or `/.git/config`, with a 404. `/.well-known/` included: serve it
    /// with a route of its own, or turn this off.
    ///
    /// On Windows a segment with a `~` is a 404 too, since it can be the
    /// 8.3 short name of a dotfile: `ENV~1` for `.env`.
    hide_dotfiles: bool = true,
    /// Answer a path that resolves outside the directory, through a
    /// symlink say, with a 404. How far that holds depends on the platform
    /// and the `Io`: `std.Io.Threaded` ignores it where the OS has no
    /// such open flag, and zio, stricter, fails the open where it cannot
    /// guarantee it. Without it, symlinks are followed wherever they lead.
    resolve_beneath: bool = false,
};

pub const Precompressed = enum {
    br,
    zstd,
    gzip,

    /// The `Content-Encoding` name.
    fn name(self: Precompressed) []const u8 {
        return @tagName(self);
    }

    fn extension(self: Precompressed) []const u8 {
        return switch (self) {
            .br => ".br",
            .zstd => ".zst",
            .gzip => ".gz",
        };
    }
};

/// The files under one directory, served by the routes `Router.static`
/// registers for it.
pub const Static = struct {
    dir: std.Io.Dir,
    options: StaticOptions,

    /// The wildcard the routes capture the path under.
    pub const param = "path";

    /// False when there is no file to serve, which the caller answers with
    /// its 404.
    pub fn serve(self: *const Static, req: *Request, res: *Response) !bool {
        const raw = req.params.get(param) orelse "";
        const sub_path = try cleanPath(req.arena, raw, self.options.hide_dotfiles) orelse return false;
        const open: Response.SendFileOptions = .{ .resolve_beneath = self.options.resolve_beneath };

        const url_path = urlPath(req.url);
        var served = sub_path;
        var stat = blk: {
            if (sub_path.len > 0) {
                if (res.sendFile(self.dir, sub_path, open)) |stat| {
                    // A file is not a directory to have a slash after it.
                    if (std.mem.endsWith(u8, url_path, "/")) return false;
                    break :blk stat;
                } else |err| switch (err) {
                    error.IsDir => {},
                    else => |e| return if (isMissing(e)) false else e,
                }
            }

            const index = self.options.index orelse return false;
            // Relative links in the index resolve against the directory
            // only when the URL ends with a slash.
            if (!std.mem.endsWith(u8, url_path, "/")) {
                const query = req.url[url_path.len..];
                // A leading `//` would make the Location another host.
                const path = std.mem.trimStart(u8, url_path, "/");
                res.status = .moved_permanently;
                try res.header("Location", try std.fmt.allocPrint(req.arena, "/{s}/{s}", .{ path, query }));
                return true;
            }
            served = if (sub_path.len == 0)
                index
            else
                try std.fmt.allocPrint(req.arena, "{s}/{s}", .{ sub_path, index });
            break :blk res.sendFile(self.dir, served, open) catch |err| {
                return if (isMissing(err)) false else err;
            };
        };

        res.content_type = .fromExtension(extension(served));

        var encoding: ?Precompressed = null;
        if (self.options.precompressed.len > 0) {
            // Which file is served depends on Accept-Encoding, whichever it
            // turns out to be.
            try addVary(req, res);
            for (self.options.precompressed) |candidate| {
                if (!http.acceptsEncoding(&req.headers, candidate.name())) continue;
                const path = try std.mem.concat(req.arena, u8, &.{ served, candidate.extension() });
                if (res.sendFile(self.dir, path, open)) |compressed| {
                    stat = compressed;
                    encoding = candidate;
                    break;
                } else |err| {
                    if (!isMissing(err)) return err;
                }
            }
        }
        if (encoding) |e| try res.header("Content-Encoding", e.name());

        const etag = try formatEtag(req.arena, stat, encoding);
        const mtime = mtimeSeconds(stat);
        try res.header("ETag", etag);
        try res.header("Last-Modified", try formatHttpDate(req.arena, mtime));
        try res.header("Accept-Ranges", "bytes");

        switch (checkPreconditions(req, etag, mtime)) {
            .proceed => {},
            .not_modified => {
                res.status = .not_modified;
                return true;
            },
            .failed => {
                res.resetBody();
                res.status = .precondition_failed;
                return true;
            },
        }

        // RFC 9110 defines ranges for GET only; a HEAD gets the whole length.
        if (req.method != .get) return true;
        const range = req.headers.get("Range") orelse return true;
        if (req.headers.get("If-Range")) |value| {
            if (!ifRangeMatches(value, etag, mtime)) return true;
        }
        const size = res.file.?.size;
        switch (parseRange(range, size)) {
            .ignore => {},
            .unsatisfiable => {
                res.resetBody();
                res.status = .range_not_satisfiable;
                try res.header("Content-Range", try std.fmt.allocPrint(req.arena, "bytes */{d}", .{size}));
            },
            .satisfiable => |r| {
                res.status = .partial_content;
                try res.header("Content-Range", try std.fmt.allocPrint(req.arena, "bytes {d}-{d}/{d}", .{ r.start, r.start + r.len - 1, size }));
                res.file.?.offset = r.start;
                res.file.?.size = r.len;
            },
        }
        return true;
    }
};

const Precondition = enum { proceed, not_modified, failed };

/// The conditional headers, in the order RFC 9110 §13.2.2 evaluates them. A
/// date that does not parse is ignored, as is the header carrying it.
fn checkPreconditions(req: *const Request, etag: []const u8, mtime: i64) Precondition {
    if (req.headers.get("If-Match")) |value| {
        if (!etagListMatches(value, etag, .strong)) return .failed;
    } else if (req.headers.get("If-Unmodified-Since")) |value| {
        if (parseHttpDate(value)) |date| {
            if (mtime > date) return .failed;
        }
    }
    if (req.headers.get("If-None-Match")) |value| {
        if (etagListMatches(value, etag, .weak)) return .not_modified;
    } else if (req.headers.get("If-Modified-Since")) |value| {
        if (parseHttpDate(value)) |date| {
            if (mtime <= date) return .not_modified;
        }
    }
    return .proceed;
}

/// An `If-Range` is one validator, an entity tag compared strongly or a date
/// that has to be the `Last-Modified` exactly.
fn ifRangeMatches(value: []const u8, etag: []const u8, mtime: i64) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (std.mem.startsWith(u8, trimmed, "\"") or std.mem.startsWith(u8, trimmed, "W/")) {
        return std.mem.eql(u8, trimmed, etag);
    }
    const date = parseHttpDate(trimmed) orelse return false;
    return date == mtime;
}

const RangeResult = union(enum) {
    /// No usable range: the whole file goes out.
    ignore,
    unsatisfiable,
    satisfiable: struct { start: u64, len: usize },
};

/// A single byte range. More than one is answered with the whole file,
/// which RFC 9110 §14.2 allows, rather than a multipart body.
fn parseRange(value: []const u8, size: usize) RangeResult {
    const unit = "bytes=";
    if (value.len < unit.len or !std.ascii.eqlIgnoreCase(value[0..unit.len], unit)) return .ignore;
    const spec = std.mem.trim(u8, value[unit.len..], " \t");
    if (std.mem.findScalar(u8, spec, ',') != null) return .ignore;
    const dash = std.mem.findScalar(u8, spec, '-') orelse return .ignore;
    const first = spec[0..dash];
    const last = spec[dash + 1 ..];

    if (first.len == 0) {
        // The last `n` bytes.
        const n = parseDecimal(u64, last) orelse return .ignore;
        if (n == 0 or size == 0) return .unsatisfiable;
        const len: usize = @intCast(@min(n, size));
        return .{ .satisfiable = .{ .start = size - len, .len = len } };
    }

    const start = parseDecimal(u64, first) orelse return .ignore;
    var end: u64 = std.math.maxInt(u64);
    if (last.len > 0) {
        end = parseDecimal(u64, last) orelse return .ignore;
        if (end < start) return .ignore;
    }
    if (start >= size) return .unsatisfiable;
    end = @min(end, size - 1);
    return .{ .satisfiable = .{ .start = start, .len = @intCast(end - start + 1) } };
}

fn isMissing(err: Response.SendFileError) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.IsDir,
        error.NotFile,
        error.AccessDenied,
        error.BadPathName,
        error.NameTooLong,
        error.SymLinkLoop,
        => true,
        else => false,
    };
}

/// The request path without its query.
fn urlPath(url: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, url, '?') orelse url.len;
    return url[0..end];
}

fn extension(path: []const u8) []const u8 {
    const name_start = if (std.mem.findScalarLast(u8, path, '/')) |i| i + 1 else 0;
    const dot = std.mem.findScalarLast(u8, path[name_start..], '.') orelse return "";
    return path[name_start + dot + 1 ..];
}

/// Turns the path a route captured, still percent-encoded, into one that
/// is relative to the served directory and cannot leave it. Null for a
/// path that is malformed or tries to.
fn cleanPath(allocator: std.mem.Allocator, raw: []const u8, hide_dotfiles: bool) !?[]const u8 {
    const decoded = try allocator.alloc(u8, raw.len);
    var len: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (len += 1) {
        if (raw[i] == '%') {
            if (raw.len - i < 3) return null;
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return null;
            decoded[len] = hi << 4 | lo;
            i += 3;
        } else {
            decoded[len] = raw[i];
            i += 1;
        }
    }

    const out = try allocator.alloc(u8, len);
    var out_len: usize = 0;
    var segments = std.mem.splitScalar(u8, decoded[0..len], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return null;
        if (hide_dotfiles) {
            if (segment[0] == '.') return null;
            if (builtin.os.tag == .windows and std.mem.findScalar(u8, segment, '~') != null) return null;
        }
        for (segment) |c| switch (c) {
            0, '\\' => return null,
            ':' => if (builtin.os.tag == .windows) return null,
            else => {},
        };
        if (out_len > 0) {
            out[out_len] = '/';
            out_len += 1;
        }
        @memcpy(out[out_len..][0..segment.len], segment);
        out_len += segment.len;
    }
    return out[0..out_len];
}

/// Digits only: `parseInt` would also take a sign.
fn parseDecimal(comptime T: type, digits: []const u8) ?T {
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(T, digits, 10) catch null;
}

fn mtimeSeconds(stat: std.Io.File.Stat) i64 {
    return @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s));
}

const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// IMF-fixdate, the HTTP date format: `Sun, 06 Nov 1994 08:49:37 GMT`. A
/// time before 1970 is given as 1970.
fn formatHttpDate(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[day.day % 7],
        month_day.day_index + 1,
        month_names[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// Seconds since the epoch for an IMF-fixdate, or null for anything else.
/// RFC 9110 also asks for the obsolete RFC 850 and asctime forms, which
/// clients only send back when the server sent them.
fn parseHttpDate(value: []const u8) ?i64 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len != 29) return null;
    if (v[3] != ',' or v[4] != ' ' or v[7] != ' ' or v[11] != ' ' or v[16] != ' ' or v[19] != ':' or v[22] != ':') return null;
    if (!std.mem.eql(u8, v[25..], " GMT")) return null;

    const day = parseDecimal(u8, v[5..7]) orelse return null;
    const month: u8 = for (month_names, 1..) |name, i| {
        if (std.mem.eql(u8, v[8..11], name)) break @intCast(i);
    } else return null;
    const year = parseDecimal(u16, v[12..16]) orelse return null;
    const hour = parseDecimal(u8, v[17..19]) orelse return null;
    const minute = parseDecimal(u8, v[20..22]) orelse return null;
    const second = parseDecimal(u8, v[23..25]) orelse return null;
    if (day == 0 or day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    return daysFromCivil(year, month, day) * std.time.s_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

/// Days from 1970-01-01 to a date in the proleptic Gregorian calendar.
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    // Counting months from March puts the leap day last.
    const month_from_march: i64 = (month + 9) % 12;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// From the file's mtime and size, and the encoding of a compressed copy,
/// which could otherwise match the plain file by chance.
fn formatEtag(allocator: std.mem.Allocator, stat: std.Io.File.Stat, encoding: ?Precompressed) ![]const u8 {
    const mtime: u96 = @bitCast(stat.mtime.nanoseconds);
    if (encoding) |e| return std.fmt.allocPrint(allocator, "\"{x}-{x}-{s}\"", .{ mtime, stat.size, e.name() });
    return std.fmt.allocPrint(allocator, "\"{x}-{x}\"", .{ mtime, stat.size });
}

/// Adds Accept-Encoding to the `Vary` a middleware may already have set.
fn addVary(req: *const Request, res: *Response) !void {
    const existing = res.headers.get("Vary") orelse return res.header("Vary", "Accept-Encoding");
    var names = std.mem.splitScalar(u8, existing, ',');
    while (names.next()) |item| {
        const item_name = std.mem.trim(u8, item, " \t");
        if (std.mem.eql(u8, item_name, "*") or std.ascii.eqlIgnoreCase(item_name, "Accept-Encoding")) return;
    }
    try res.header("Vary", try std.fmt.allocPrint(req.arena, "{s}, Accept-Encoding", .{existing}));
}

/// An `If-Match` or `If-None-Match` list against a strong `ETag`. The weak
/// comparison `If-None-Match` uses ignores a `W/`; the strong one `If-Match`
/// uses never matches a weak tag.
fn etagListMatches(value: []const u8, etag: []const u8, comparison: enum { weak, strong }) bool {
    if (std.mem.eql(u8, std.mem.trim(u8, value, " \t"), "*")) return true;
    var candidates = std.mem.splitScalar(u8, value, ',');
    while (candidates.next()) |candidate| {
        var tag = std.mem.trim(u8, candidate, " \t");
        if (std.mem.startsWith(u8, tag, "W/")) {
            if (comparison == .strong) continue;
            tag = tag[2..];
        }
        if (std.mem.eql(u8, tag, etag)) return true;
    }
    return false;
}

test cleanPath {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("a/b.css", (try cleanPath(a, "/a//./b.css", false)).?);
    try std.testing.expectEqualStrings("a b/c", (try cleanPath(a, "a%20b/c", false)).?);
    try std.testing.expectEqualStrings("a+b", (try cleanPath(a, "a+b", false)).?);
    try std.testing.expectEqualStrings("", (try cleanPath(a, "/", false)).?);
    try std.testing.expectEqual(null, try cleanPath(a, "a/../b", false));
    try std.testing.expectEqual(null, try cleanPath(a, "a/%2E%2e/b", false));
    try std.testing.expectEqual(null, try cleanPath(a, "a%2f..%2fb", false));
    try std.testing.expectEqual(null, try cleanPath(a, "a%5cb", false));
    try std.testing.expectEqual(null, try cleanPath(a, "a%00b", false));
    try std.testing.expectEqual(null, try cleanPath(a, "a%2", false));
    try std.testing.expectEqual(null, try cleanPath(a, "a%+1", false));
    try std.testing.expectEqualStrings(".well-known/x", (try cleanPath(a, "/.well-known/x", false)).?);
    try std.testing.expectEqual(null, try cleanPath(a, "/.well-known/x", true));
    try std.testing.expectEqual(null, try cleanPath(a, "a/%2Egit/config", true));
}

test etagListMatches {
    try std.testing.expect(etagListMatches("\"1-2\"", "\"1-2\"", .weak));
    try std.testing.expect(etagListMatches("W/\"1-2\"", "\"1-2\"", .weak));
    try std.testing.expect(etagListMatches("\"0-0\", W/\"1-2\"", "\"1-2\"", .weak));
    try std.testing.expect(etagListMatches(" * ", "\"1-2\"", .weak));
    try std.testing.expect(!etagListMatches("\"1-3\"", "\"1-2\"", .weak));
    try std.testing.expect(etagListMatches("\"1-2\"", "\"1-2\"", .strong));
    try std.testing.expect(!etagListMatches("W/\"1-2\"", "\"1-2\"", .strong));
}

test parseRange {
    const expectRange = struct {
        fn f(value: []const u8, start: u64, len: usize) !void {
            const r = parseRange(value, 100);
            try std.testing.expectEqual(start, r.satisfiable.start);
            try std.testing.expectEqual(len, r.satisfiable.len);
        }
    }.f;
    try expectRange("bytes=0-9", 0, 10);
    try expectRange("bytes=90-", 90, 10);
    try expectRange("bytes=90-1000", 90, 10);
    try expectRange("bytes=-10", 90, 10);
    try expectRange("bytes=-1000", 0, 100);
    try expectRange("Bytes=5-5", 5, 1);
    try std.testing.expectEqual(.unsatisfiable, parseRange("bytes=100-", 100));
    try std.testing.expectEqual(.unsatisfiable, parseRange("bytes=-0", 100));
    try std.testing.expectEqual(.unsatisfiable, parseRange("bytes=0-", 0));
    try std.testing.expectEqual(.ignore, parseRange("bytes=0-1,5-6", 100));
    try std.testing.expectEqual(.ignore, parseRange("bytes=9-0", 100));
    try std.testing.expectEqual(.ignore, parseRange("bytes=+1-2", 100));
    try std.testing.expectEqual(.ignore, parseRange("items=0-1", 100));
}

test "HTTP date round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", try formatHttpDate(arena.allocator(), 784111777));
    try std.testing.expectEqual(784111777, parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try std.testing.expectEqual(951782400, parseHttpDate("Tue, 29 Feb 2000 00:00:00 GMT"));
    try std.testing.expectEqual(null, parseHttpDate("Sun, 29 Feb 1999 00:00:00 GMT"));
    try std.testing.expectEqual(null, parseHttpDate("Sunday, 06-Nov-94 08:49:37 GMT"));
    try std.testing.expectEqual(null, parseHttpDate("Sun, 06 Nov 1994 08:49:37 UTC"));
}
