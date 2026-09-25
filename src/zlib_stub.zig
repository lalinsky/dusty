//! Stub used when the `use_zlib` build option is disabled.
//!
//! It mirrors just enough of the zlib.zig API surface for `parser.zig` to
//! type check. The bodies are never reached: `startDecoding` refuses gzip and
//! deflate with `error.UnsupportedContentEncoding` up front when `use_zlib`
//! is false.

const std = @import("std");

pub const Container = enum { raw, zlib, gzip };

pub const Decompress = struct {
    reader: std.Io.Reader,
    err: ?Error = null,

    pub const Error = error{
        ReadFailed,
        CorruptInput,
        TruncatedInput,
        OutOfMemory,
    };

    pub const Options = struct {
        window_bits: u4 = 15,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        input: *std.Io.Reader,
        buffer: []u8,
        container: Container,
        options: Options,
    ) error{UnsupportedContentEncoding}!Decompress {
        _ = allocator;
        _ = input;
        _ = buffer;
        _ = container;
        _ = options;
        return error.UnsupportedContentEncoding;
    }
};
