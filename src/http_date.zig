const std = @import("std");

const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
pub const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub const len = "Sun, 06 Nov 1994 08:49:37 GMT".len;

/// IMF-fixdate, the HTTP date format: `Sun, 06 Nov 1994 08:49:37 GMT`. A
/// time before 1970 is given as 1970, and one past 9999 as the end of 9999.
pub fn format(buf: *[len]u8, seconds: i64) void {
    const last_second_of_9999 = 253402300799;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.math.clamp(seconds, 0, last_second_of_9999)) };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    _ = std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[day.day % 7],
        month_day.day_index + 1,
        month_names[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

const prefix = "Date: ";
pub const line_len = prefix.len + len + "\r\n".len;

/// The `Date` header line for a time, as `format` gives it.
pub fn formatLine(buf: *[line_len]u8, seconds: i64) void {
    buf[0..prefix.len].* = prefix.*;
    format(buf[prefix.len..][0..len], seconds);
    buf[prefix.len + len ..].* = "\r\n".*;
}

const Cache = struct {
    second: i64 = std.math.minInt(i64),
    line: [line_len]u8 = undefined,
};

threadlocal var cache: Cache = .{};

/// The `Date` header line for the current second of the wall clock,
/// reformatted only when the second changes. Returned by value, since a task
/// can move to another thread mid-write and leave this thread's cache to be
/// rewritten under it.
pub fn line(io: std.Io) [line_len]u8 {
    const second = std.Io.Timestamp.now(io, .real).toSeconds();
    if (second != cache.second) {
        formatLine(&cache.line, second);
        cache.second = second;
    }
    return cache.line;
}
