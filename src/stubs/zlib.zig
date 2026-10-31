//! Stub used when the `use_zlib` build option is disabled.
//!
//! It mirrors just enough of the zlib.zig API surface for `parser.zig` and
//! `response.zig` to type check. The bodies are never reached: `startDecoding`
//! refuses gzip and deflate with `error.UnsupportedContentEncoding` up front
//! when `use_zlib` is false, and a response is never compressed.

const std = @import("std");

pub const Container = enum { raw, zlib, gzip };

pub const Level = enum(c_int) {
    default = -1,
    _,
};

pub const Options = struct {
    level: Level = .default,
    window_bits: u4 = 15,
    mem_level: u4 = 8,
};

pub const Compress = struct {
    writer: std.Io.Writer,

    pub fn init(
        allocator: std.mem.Allocator,
        output: *std.Io.Writer,
        buffer: []u8,
        container: Container,
        options: Options,
    ) std.mem.Allocator.Error!Compress {
        _ = allocator;
        _ = output;
        _ = buffer;
        _ = container;
        _ = options;
        unreachable;
    }

    pub fn deinit(self: *Compress) void {
        _ = self;
        unreachable;
    }

    pub fn finish(self: *Compress) std.Io.Writer.Error!void {
        _ = self;
        unreachable;
    }
};

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
        options: Decompress.Options,
    ) error{UnsupportedContentEncoding}!Decompress {
        _ = allocator;
        _ = input;
        _ = buffer;
        _ = container;
        _ = options;
        return error.UnsupportedContentEncoding;
    }
};
