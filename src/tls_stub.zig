//! Stub used when the `use_tls` build option is disabled.
//!
//! It mirrors just enough of the tls.zig API surface for `client.zig` to type
//! check. The bodies are never reached: the HTTPS path in `Connection.init`
//! returns `error.TlsNotConfigured` up front when `use_tls` is false.

const std = @import("std");

pub const input_buffer_len: usize = 0;
pub const output_buffer_len: usize = 0;

pub fn client(input: *std.Io.Reader, output: *std.Io.Writer, opt: anytype) !Connection {
    _ = input;
    _ = output;
    _ = opt;
    return error.TlsNotConfigured;
}

pub const Connection = struct {
    pub const Reader = struct { interface: std.Io.Reader };
    pub const Writer = struct { interface: std.Io.Writer };

    pub fn reader(self: *Connection, buffer: []u8) Reader {
        _ = self;
        _ = buffer;
        unreachable;
    }

    pub fn writer(self: *Connection, buffer: []u8) Writer {
        _ = self;
        _ = buffer;
        unreachable;
    }
};
