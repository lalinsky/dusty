//! The TLS module behind one face. Dusty is written to tls.zig's API, and
//! ztls follows it closely but not exactly: it takes an allocator in its
//! options, verifies against a prebuilt trust store rather than a
//! `std.crypto.Certificate.Bundle`, and draws its own randomness.
//! Everything that differs goes through here, so the rest of the library
//! sees one API whichever module was injected as `tls`.

const std = @import("std");
const backend = @import("tls");

/// Which of the two APIs the injected module has.
pub const is_ztls = @hasDecl(backend, "is_ztls");

pub const input_buffer_len = backend.input_buffer_len;
pub const output_buffer_len = backend.output_buffer_len;
pub const Connection = backend.Connection;
pub const CertKeyPair = backend.config.CertKeyPair;

/// `CertKeyPair.fromSlice`.
pub fn certKeyPairFromSlice(allocator: std.mem.Allocator, io: std.Io, cert_pem: []const u8, key_pem: []const u8) !CertKeyPair {
    if (is_ztls) return CertKeyPair.fromSlice(allocator, cert_pem, key_pem);
    return CertKeyPair.fromSlice(allocator, io, cert_pem, key_pem);
}

/// The certificate authorities one side trusts, in the form the module
/// verifies against. Built once and shared read-only by every connection.
pub const Trust = if (is_ztls) StoreTrust else BundleTrust;

/// ztls: AWS-LC's X.509 store, fed certificates one by one.
const StoreTrust = struct {
    store: backend.TrustStore,

    pub fn init() !Trust {
        return .{ .store = try backend.TrustStore.init() };
    }

    pub fn deinit(self: *Trust, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.store.deinit();
    }

    pub fn addSystem(self: *Trust, allocator: std.mem.Allocator, io: std.Io) !void {
        try self.store.addSystemBundle(allocator, io);
    }

    pub fn addFile(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.store.addPemFile(allocator, io, dir, path);
    }

    pub fn addDir(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        var sub_dir = try dir.openDir(io, path, .{ .iterate = true });
        defer sub_dir.close(io);
        try self.store.addPemDir(allocator, io, sub_dir);
    }

    pub fn addPem(self: *Trust, allocator: std.mem.Allocator, io: std.Io, pem: []const u8) !void {
        _ = io;
        try self.store.addPem(allocator, pem);
    }
};

/// tls.zig: std's certificate bundle.
const BundleTrust = struct {
    bundle: std.crypto.Certificate.Bundle,

    pub fn init() !Trust {
        return .{ .bundle = .empty };
    }

    pub fn deinit(self: *Trust, allocator: std.mem.Allocator) void {
        self.bundle.deinit(allocator);
    }

    pub fn addSystem(self: *Trust, allocator: std.mem.Allocator, io: std.Io) !void {
        try self.bundle.rescan(allocator, io, std.Io.Clock.real.now(io));
    }

    pub fn addFile(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.bundle.addCertsFromFilePath(allocator, io, std.Io.Clock.real.now(io), dir, path);
    }

    pub fn addDir(self: *Trust, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        try self.bundle.addCertsFromDirPath(allocator, io, dir, path);
    }

    /// `Bundle.addCertsFromFile` for PEM text already in memory.
    pub fn addPem(self: *Trust, allocator: std.mem.Allocator, io: std.Io, pem: []const u8) !void {
        const now_sec = std.Io.Clock.real.now(io).toSeconds();
        const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
        const begin_marker = "-----BEGIN CERTIFICATE-----";
        const end_marker = "-----END CERTIFICATE-----";

        const decoded_size_upper_bound = std.math.cast(u32, pem.len / 4 * 3) orelse
            return error.CertificateAuthorityBundleTooBig;
        try self.bundle.bytes.ensureUnusedCapacity(allocator, decoded_size_upper_bound);

        var start_index: usize = 0;
        while (std.mem.findPos(u8, pem, start_index, begin_marker)) |begin_marker_start| {
            const cert_start = begin_marker_start + begin_marker.len;
            const cert_end = std.mem.findPos(u8, pem, cert_start, end_marker) orelse
                return error.MissingEndCertificateMarker;
            start_index = cert_end + end_marker.len;
            const encoded_cert = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
            const decoded_start: u32 = @intCast(self.bundle.bytes.items.len);
            const dest_buf = self.bundle.bytes.allocatedSlice()[decoded_start..];
            self.bundle.bytes.items.len += try base64.decode(dest_buf, encoded_cert);
            try self.bundle.parseCert(allocator, decoded_start, now_sec);
        }
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
    const now = std.Io.Clock.real.now(o.io);
    if (is_ztls) return backend.client(input, output, .{
        .allocator = o.allocator,
        .host = o.host,
        .root_ca = &o.trust.store,
        .insecure_skip_verify = o.insecure_skip_verify,
        .auth = o.auth,
        .alpn_protocols = o.alpn_protocols,
        .now = now,
    });
    return backend.client(input, output, .{
        .host = o.host,
        .root_ca = o.trust.bundle,
        .insecure_skip_verify = o.insecure_skip_verify,
        .auth = o.auth,
        .alpn_protocols = o.alpn_protocols,
        .now = now,
        .rng = o.rng,
    });
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
    const now = std.Io.Clock.real.now(o.io);
    if (is_ztls) return backend.server(input, output, .{
        .allocator = o.allocator,
        .auth = o.auth,
        .client_auth = if (o.client_auth) |ca| .{
            .root_ca = &ca.trust.store,
            .auth_type = switch (ca.mode) {
                .request => .request,
                .require => .require,
            },
        } else null,
        .alpn_protocols = o.alpn_protocols,
        .now = now,
    });
    return backend.server(input, output, .{
        .auth = o.auth,
        .client_auth = if (o.client_auth) |ca| .{
            .root_ca = ca.trust.bundle,
            .auth_type = switch (ca.mode) {
                .request => .request,
                .require => .require,
            },
        } else null,
        .alpn_protocols = o.alpn_protocols,
        .now = now,
        .rng = o.rng,
    });
}
