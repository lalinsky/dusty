//! An asset bundle made by `addAssets` in dusty's build.zig: the files of a
//! directory, embedded, each linked to with a hash of its content in the URL.

const std = @import("std");
const table = @import("files.zig");

pub const File = struct {
    /// The path relative to the bundle's directory, `img/logo.png`.
    name: []const u8,
    /// Where it is served, `/assets/img/logo.png`.
    path: []const u8,
    /// A hash of the content.
    version: []const u8,
    /// What to link to, `/assets/img/logo.png?v=1a2b3c4d`.
    url: []const u8,
    data: []const u8,
    br: ?[]const u8 = null,
    zstd: ?[]const u8 = null,
    gzip: ?[]const u8 = null,
};

pub const prefix = table.prefix;
pub const files: []const File = &table.files;

/// The URL a file is served under, for a template to link to. A name
/// that is not in the bundle is a compile error.
pub fn url(comptime name: []const u8) []const u8 {
    inline for (table.files) |file| {
        if (comptime std.mem.eql(u8, file.name, name)) return file.url;
    }
    @compileError("no asset named \"" ++ name ++ "\" in the bundle");
}

/// Registers every file with `router.embedded`. A request with the current
/// version in `?v=` is answered as cacheable for good, any other with
/// `no-cache`, so a page still open from before a deploy gets the current
/// content rather than a 404. A `Group` works too, but its prefix goes in
/// front of the bundle's own.
pub fn register(router: anytype) void {
    for (files) |file| {
        router.embedded(file.path, file.data, .{
            .br = file.br,
            .zstd = file.zstd,
            .gzip = file.gzip,
            .version = file.version,
            .cache_control = "no-cache",
        });
    }
}
