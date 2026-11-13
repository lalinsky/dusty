//! The TLS module behind one face. Dusty builds with ztls, or with a module
//! the application injects, such as tls.zig. Their APIs have the same
//! shape but differ in the details: what the allocator is called, whether
//! they take `io`, `now` or `rng`, and what they verify against. Rather than
//! asking which library it is, this reads the options the module declares
//! and fills in the ones it has, so the rest of Dusty sees one API.

const std = @import("std");
const build_options = @import("build_options");
const backend = @import("tls");

const enabled = build_options.use_tls;

pub const input_buffer_len = backend.input_buffer_len;
pub const output_buffer_len = backend.output_buffer_len;
pub const Connection = backend.Connection;
pub const CertKeyPair = backend.config.CertKeyPair;

/// Whether the module has `Connection.writerInPlace`.
pub const has_writer_in_place = @hasDecl(Connection, "writerInPlace");

/// Frees what the connection holds. A module backed by C code, like ztls,
/// has state to free; tls.zig's connection has none and no `deinit`.
pub fn deinitConnection(conn: *Connection) void {
    if (@hasDecl(Connection, "deinit")) conn.deinit();
}

/// `CertKeyPair.fromSlice`, which takes `io` in some modules.
pub fn certKeyPairFromSlice(allocator: std.mem.Allocator, io: std.Io, cert_pem: []const u8, key_pem: []const u8) !CertKeyPair {
    // A fourth argument, the tuple's field "3", is `io`.
    if (comptime @hasField(std.meta.ArgsTuple(@TypeOf(CertKeyPair.fromSlice)), "3")) {
        return CertKeyPair.fromSlice(allocator, io, cert_pem, key_pem);
    }
    return CertKeyPair.fromSlice(allocator, cert_pem, key_pem);
}

/// What the module verifies a peer's certificate against: its client
/// options' `root_ca`, by value or through a pointer.
const RootCa = @FieldType(backend.config.Client, "root_ca");

/// The type `root_ca` points to, or `RootCa` itself when it is a value.
const TrustValue = switch (@typeInfo(RootCa)) {
    .optional => |o| @typeInfo(o.child).pointer.child,
    .pointer => |p| p.child,
    else => RootCa,
};

/// The certificate authorities one side trusts, in the form the module
/// verifies against. Built once and shared read-only by every connection.
pub const Trust = if (!enabled)
    NoTrust
else if (TrustValue == std.crypto.Certificate.Bundle)
    BundleTrust
else
    StoreTrust;

/// `trust` as the `root_ca` field of the module's options struct `T`.
fn rootCa(comptime T: type, trust: *const Trust) @FieldType(T, "root_ca") {
    return switch (@typeInfo(@FieldType(T, "root_ca"))) {
        .optional, .pointer => &trust.value,
        else => trust.value,
    };
}

/// A trust store the module builds itself, like ztls's AWS-LC one, fed
/// certificates one by one.
const StoreTrust = struct {
    value: TrustValue,

    pub fn init() !Trust {
        return .{ .value = try TrustValue.init() };
    }

    pub fn deinit(self: *Trust, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.value.deinit();
    }

    pub fn addSystem(self: *Trust, allocator: std.mem.Allocator, io: std.Io) !void {
        try self.value.addSystemBundle(allocator, io);
    }

    pub fn addFile(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.value.addPemFile(allocator, io, dir, path);
    }

    pub fn addDir(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        var sub_dir = try dir.openDir(io, path, .{ .iterate = true });
        defer sub_dir.close(io);
        try self.value.addPemDir(allocator, io, sub_dir);
    }

    pub fn addPem(self: *Trust, allocator: std.mem.Allocator, io: std.Io, pem: []const u8) !void {
        _ = io;
        try self.value.addPem(allocator, pem);
    }
};

/// std's certificate bundle, which tls.zig verifies against.
const BundleTrust = struct {
    value: std.crypto.Certificate.Bundle,

    pub fn init() !Trust {
        return .{ .value = .empty };
    }

    pub fn deinit(self: *Trust, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }

    pub fn addSystem(self: *Trust, allocator: std.mem.Allocator, io: std.Io) !void {
        try self.value.rescan(allocator, io, std.Io.Clock.real.now(io));
    }

    pub fn addFile(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.value.addCertsFromFilePath(allocator, io, std.Io.Clock.real.now(io), dir, path);
    }

    pub fn addDir(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.value.addCertsFromDirPath(allocator, io, dir, path);
    }

    /// `Bundle.addCertsFromFile` for PEM text already in memory.
    pub fn addPem(self: *Trust, allocator: std.mem.Allocator, io: std.Io, pem: []const u8) !void {
        const now_sec = std.Io.Clock.real.now(io).toSeconds();
        const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const begin_marker = "-----BEGIN CERTIFICATE-----";
        const end_marker = "-----END CERTIFICATE-----";

        const decoded_size_upper_bound = std.math.cast(u32, pem.len / 4 * 3) orelse
            return error.CertificateAuthorityBundleTooBig;
        try self.value.bytes.ensureUnusedCapacity(allocator, decoded_size_upper_bound);

        var start_index: usize = 0;
        while (std.mem.findPos(u8, pem, start_index, begin_marker)) |begin_marker_start| {
            const cert_start = begin_marker_start + begin_marker.len;
            const cert_end = std.mem.findPos(u8, pem, cert_start, end_marker) orelse
                return error.MissingEndCertificateMarker;
            start_index = cert_end + end_marker.len;
            const encoded_cert = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
            const decoded_start: u32 = @intCast(self.value.bytes.items.len);
            const dest_buf = self.value.bytes.allocatedSlice()[decoded_start..];
            self.value.bytes.items.len += try base64.decode(dest_buf, encoded_cert);
            try self.value.parseCert(allocator, decoded_start, now_sec);
        }
    }
};

/// Built without TLS: nothing can be loaded, and nothing is verified.
const NoTrust = struct {
    pub fn init() !Trust {
        return error.TlsNotConfigured;
    }

    pub fn deinit(self: *Trust, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn addSystem(self: *Trust, allocator: std.mem.Allocator, io: std.Io) !void {
        _ = .{ self, allocator, io };
        return error.TlsNotConfigured;
    }

    pub fn addFile(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        _ = .{ self, allocator, io, dir, path };
        return error.TlsNotConfigured;
    }

    pub fn addDir(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        _ = .{ self, allocator, io, dir, path };
        return error.TlsNotConfigured;
    }

    pub fn addPem(self: *Trust, allocator: std.mem.Allocator, io: std.Io, pem: []const u8) !void {
        _ = .{ self, allocator, io, pem };
        return error.TlsNotConfigured;
    }
};

pub const ClientAuthMode = enum { request, require };

pub const ClientOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// SNI, and the name the server's certificate must carry.
    host: []const u8,
    trust: *const Trust,
    insecure_skip_verify: bool = false,
    /// Presented when the server asks for a client certificate.
    auth: ?*CertKeyPair = null,
    alpn_protocols: []const []const u8 = &.{},
    rng: std.Random,
};

pub fn client(input: *std.Io.Reader, output: *std.Io.Writer, o: ClientOptions) !Connection {
    if (!enabled) return error.TlsNotConfigured;
    return backend.client(input, output, fill(backend.config.Client, o.io, .{
        .allocator = o.allocator,
        .gpa = o.allocator,
        .io = o.io,
        .host = o.host,
        .root_ca = rootCa(backend.config.Client, o.trust),
        .insecure_skip_verify = o.insecure_skip_verify,
        .auth = o.auth,
        .alpn_protocols = o.alpn_protocols,
        .rng = o.rng,
    }));
}

pub const ClientAuth = struct {
    trust: *const Trust,
    mode: ClientAuthMode,
};

pub const ServerOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    auth: *CertKeyPair,
    client_auth: ?ClientAuth = null,
    alpn_protocols: []const []const u8 = &.{},
    rng: std.Random,
};

pub fn server(input: *std.Io.Reader, output: *std.Io.Writer, o: ServerOptions) !Connection {
    if (!enabled) return error.TlsNotConfigured;
    const Options = backend.config.Server;
    const BackendClientAuth = @typeInfo(@FieldType(Options, "client_auth")).optional.child;
    const AuthType = @FieldType(BackendClientAuth, "auth_type");
    return backend.server(input, output, fill(Options, o.io, .{
        .allocator = o.allocator,
        .gpa = o.allocator,
        .io = o.io,
        .auth = o.auth,
        .client_auth = if (o.client_auth) |ca| fill(BackendClientAuth, o.io, .{
            .root_ca = rootCa(BackendClientAuth, ca.trust),
            .auth_type = switch (ca.mode) {
                inline else => |mode| @field(AuthType, @tagName(mode)),
            },
        }) else null,
        .alpn_protocols = o.alpn_protocols,
        .rng = o.rng,
    }));
}

/// Builds the module's options struct `T` from `values`, by field name.
/// Values for fields `T` does not have are dropped, so `values` can name
/// the same thing in every way a module might, `allocator` and `gpa`.
/// Fields `values` does not name keep their default, except a `now` with
/// no default, which gets the current time; any other is a compile error.
fn fill(comptime T: type, io: std.Io, values: anytype) T {
    var out: T = undefined;
    inline for (comptime std.meta.fieldNames(T)) |name| {
        if (@hasField(@TypeOf(values), name)) {
            @field(out, name) = @field(values, name);
        } else if (comptime defaultValue(T, name)) |value| {
            @field(out, name) = value;
        } else if (comptime std.mem.eql(u8, name, "now")) {
            out.now = std.Io.Clock.real.now(io);
        } else {
            @compileError("Dusty has no value for the TLS module's " ++ @typeName(T) ++ "." ++ name);
        }
    }
    return out;
}

fn defaultValue(comptime T: type, comptime name: []const u8) ?@FieldType(T, name) {
    const info = @typeInfo(T).@"struct";
    // Zig 0.17 split `fields` into parallel arrays.
    if (@hasField(@TypeOf(info), "fields")) {
        for (info.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.defaultValue();
        }
    } else {
        for (info.field_names, info.field_attrs) |field_name, attrs| {
            if (std.mem.eql(u8, field_name, name)) return attrs.defaultValue(@FieldType(T, name));
        }
    }
    unreachable;
}
