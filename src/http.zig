const std = @import("std");

const c = @cImport({
    @cInclude("llhttp.h");
});

pub const Method = enum(c.llhttp_method_t) {
    delete = c.HTTP_DELETE,
    get = c.HTTP_GET,
    head = c.HTTP_HEAD,
    post = c.HTTP_POST,
    put = c.HTTP_PUT,
    connect = c.HTTP_CONNECT,
    options = c.HTTP_OPTIONS,
    trace = c.HTTP_TRACE,
    copy = c.HTTP_COPY,
    lock = c.HTTP_LOCK,
    mkcol = c.HTTP_MKCOL,
    move = c.HTTP_MOVE,
    propfind = c.HTTP_PROPFIND,
    proppatch = c.HTTP_PROPPATCH,
    search = c.HTTP_SEARCH,
    unlock = c.HTTP_UNLOCK,
    bind = c.HTTP_BIND,
    rebind = c.HTTP_REBIND,
    unbind = c.HTTP_UNBIND,
    acl = c.HTTP_ACL,
    report = c.HTTP_REPORT,
    mkactivity = c.HTTP_MKACTIVITY,
    checkout = c.HTTP_CHECKOUT,
    merge = c.HTTP_MERGE,
    msearch = c.HTTP_MSEARCH,
    notify = c.HTTP_NOTIFY,
    subscribe = c.HTTP_SUBSCRIBE,
    unsubscribe = c.HTTP_UNSUBSCRIBE,
    patch = c.HTTP_PATCH,
    purge = c.HTTP_PURGE,
    mkcalendar = c.HTTP_MKCALENDAR,
    link = c.HTTP_LINK,
    unlink = c.HTTP_UNLINK,
    source = c.HTTP_SOURCE,
    pri = c.HTTP_PRI,
    describe = c.HTTP_DESCRIBE,
    announce = c.HTTP_ANNOUNCE,
    setup = c.HTTP_SETUP,
    play = c.HTTP_PLAY,
    pause = c.HTTP_PAUSE,
    teardown = c.HTTP_TEARDOWN,
    get_parameter = c.HTTP_GET_PARAMETER,
    set_parameter = c.HTTP_SET_PARAMETER,
    redirect = c.HTTP_REDIRECT,
    record = c.HTTP_RECORD,
    flush = c.HTTP_FLUSH,
    query = c.HTTP_QUERY,

    pub fn name(self: Method) [:0]const u8 {
        return std.mem.span(c.llhttp_method_name(@intFromEnum(self)));
    }

    pub fn format(self: Method, writer: anytype) !void {
        try writer.writeAll(self.name());
    }
};

test "Method: construct from llhttp_method_t" {
    const method: Method = @enumFromInt(c.HTTP_GET);
    try std.testing.expectEqual(.get, method);
}

test "Method: name" {
    try std.testing.expectEqualStrings("GET", Method.get.name());
    try std.testing.expectEqualStrings("POST", Method.post.name());
    try std.testing.expectEqualStrings("DELETE", Method.delete.name());
}

test "Method: format" {
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{Method.get});
    try std.testing.expectEqualStrings("GET", result);
}

pub const Status = enum(c.llhttp_status_t) {
    @"continue" = c.HTTP_STATUS_CONTINUE,
    switching_protocols = c.HTTP_STATUS_SWITCHING_PROTOCOLS,
    processing = c.HTTP_STATUS_PROCESSING,
    early_hints = c.HTTP_STATUS_EARLY_HINTS,
    response_is_stale = c.HTTP_STATUS_RESPONSE_IS_STALE,
    revalidation_failed = c.HTTP_STATUS_REVALIDATION_FAILED,
    disconnected_operation = c.HTTP_STATUS_DISCONNECTED_OPERATION,
    heuristic_expiration = c.HTTP_STATUS_HEURISTIC_EXPIRATION,
    miscellaneous_warning = c.HTTP_STATUS_MISCELLANEOUS_WARNING,
    ok = c.HTTP_STATUS_OK,
    created = c.HTTP_STATUS_CREATED,
    accepted = c.HTTP_STATUS_ACCEPTED,
    non_authoritative_information = c.HTTP_STATUS_NON_AUTHORITATIVE_INFORMATION,
    no_content = c.HTTP_STATUS_NO_CONTENT,
    reset_content = c.HTTP_STATUS_RESET_CONTENT,
    partial_content = c.HTTP_STATUS_PARTIAL_CONTENT,
    multi_status = c.HTTP_STATUS_MULTI_STATUS,
    already_reported = c.HTTP_STATUS_ALREADY_REPORTED,
    transformation_applied = c.HTTP_STATUS_TRANSFORMATION_APPLIED,
    im_used = c.HTTP_STATUS_IM_USED,
    miscellaneous_persistent_warning = c.HTTP_STATUS_MISCELLANEOUS_PERSISTENT_WARNING,
    multiple_choices = c.HTTP_STATUS_MULTIPLE_CHOICES,
    moved_permanently = c.HTTP_STATUS_MOVED_PERMANENTLY,
    found = c.HTTP_STATUS_FOUND,
    see_other = c.HTTP_STATUS_SEE_OTHER,
    not_modified = c.HTTP_STATUS_NOT_MODIFIED,
    use_proxy = c.HTTP_STATUS_USE_PROXY,
    switch_proxy = c.HTTP_STATUS_SWITCH_PROXY,
    temporary_redirect = c.HTTP_STATUS_TEMPORARY_REDIRECT,
    permanent_redirect = c.HTTP_STATUS_PERMANENT_REDIRECT,
    bad_request = c.HTTP_STATUS_BAD_REQUEST,
    unauthorized = c.HTTP_STATUS_UNAUTHORIZED,
    payment_required = c.HTTP_STATUS_PAYMENT_REQUIRED,
    forbidden = c.HTTP_STATUS_FORBIDDEN,
    not_found = c.HTTP_STATUS_NOT_FOUND,
    method_not_allowed = c.HTTP_STATUS_METHOD_NOT_ALLOWED,
    not_acceptable = c.HTTP_STATUS_NOT_ACCEPTABLE,
    proxy_authentication_required = c.HTTP_STATUS_PROXY_AUTHENTICATION_REQUIRED,
    request_timeout = c.HTTP_STATUS_REQUEST_TIMEOUT,
    conflict = c.HTTP_STATUS_CONFLICT,
    gone = c.HTTP_STATUS_GONE,
    length_required = c.HTTP_STATUS_LENGTH_REQUIRED,
    precondition_failed = c.HTTP_STATUS_PRECONDITION_FAILED,
    payload_too_large = c.HTTP_STATUS_PAYLOAD_TOO_LARGE,
    uri_too_long = c.HTTP_STATUS_URI_TOO_LONG,
    unsupported_media_type = c.HTTP_STATUS_UNSUPPORTED_MEDIA_TYPE,
    range_not_satisfiable = c.HTTP_STATUS_RANGE_NOT_SATISFIABLE,
    expectation_failed = c.HTTP_STATUS_EXPECTATION_FAILED,
    im_a_teapot = c.HTTP_STATUS_IM_A_TEAPOT,
    page_expired = c.HTTP_STATUS_PAGE_EXPIRED,
    enhance_your_calm = c.HTTP_STATUS_ENHANCE_YOUR_CALM,
    misdirected_request = c.HTTP_STATUS_MISDIRECTED_REQUEST,
    unprocessable_entity = c.HTTP_STATUS_UNPROCESSABLE_ENTITY,
    locked = c.HTTP_STATUS_LOCKED,
    failed_dependency = c.HTTP_STATUS_FAILED_DEPENDENCY,
    too_early = c.HTTP_STATUS_TOO_EARLY,
    upgrade_required = c.HTTP_STATUS_UPGRADE_REQUIRED,
    precondition_required = c.HTTP_STATUS_PRECONDITION_REQUIRED,
    too_many_requests = c.HTTP_STATUS_TOO_MANY_REQUESTS,
    request_header_fields_too_large_unofficial = c.HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE_UNOFFICIAL,
    request_header_fields_too_large = c.HTTP_STATUS_REQUEST_HEADER_FIELDS_TOO_LARGE,
    login_timeout = c.HTTP_STATUS_LOGIN_TIMEOUT,
    no_response = c.HTTP_STATUS_NO_RESPONSE,
    retry_with = c.HTTP_STATUS_RETRY_WITH,
    blocked_by_parental_control = c.HTTP_STATUS_BLOCKED_BY_PARENTAL_CONTROL,
    unavailable_for_legal_reasons = c.HTTP_STATUS_UNAVAILABLE_FOR_LEGAL_REASONS,
    client_closed_load_balanced_request = c.HTTP_STATUS_CLIENT_CLOSED_LOAD_BALANCED_REQUEST,
    invalid_x_forwarded_for = c.HTTP_STATUS_INVALID_X_FORWARDED_FOR,
    request_header_too_large = c.HTTP_STATUS_REQUEST_HEADER_TOO_LARGE,
    ssl_certificate_error = c.HTTP_STATUS_SSL_CERTIFICATE_ERROR,
    ssl_certificate_required = c.HTTP_STATUS_SSL_CERTIFICATE_REQUIRED,
    http_request_sent_to_https_port = c.HTTP_STATUS_HTTP_REQUEST_SENT_TO_HTTPS_PORT,
    invalid_token = c.HTTP_STATUS_INVALID_TOKEN,
    client_closed_request = c.HTTP_STATUS_CLIENT_CLOSED_REQUEST,
    internal_server_error = c.HTTP_STATUS_INTERNAL_SERVER_ERROR,
    not_implemented = c.HTTP_STATUS_NOT_IMPLEMENTED,
    bad_gateway = c.HTTP_STATUS_BAD_GATEWAY,
    service_unavailable = c.HTTP_STATUS_SERVICE_UNAVAILABLE,
    gateway_timeout = c.HTTP_STATUS_GATEWAY_TIMEOUT,
    http_version_not_supported = c.HTTP_STATUS_HTTP_VERSION_NOT_SUPPORTED,
    variant_also_negotiates = c.HTTP_STATUS_VARIANT_ALSO_NEGOTIATES,
    insufficient_storage = c.HTTP_STATUS_INSUFFICIENT_STORAGE,
    loop_detected = c.HTTP_STATUS_LOOP_DETECTED,
    bandwidth_limit_exceeded = c.HTTP_STATUS_BANDWIDTH_LIMIT_EXCEEDED,
    not_extended = c.HTTP_STATUS_NOT_EXTENDED,
    network_authentication_required = c.HTTP_STATUS_NETWORK_AUTHENTICATION_REQUIRED,
    web_server_unknown_error = c.HTTP_STATUS_WEB_SERVER_UNKNOWN_ERROR,
    web_server_is_down = c.HTTP_STATUS_WEB_SERVER_IS_DOWN,
    connection_timeout = c.HTTP_STATUS_CONNECTION_TIMEOUT,
    origin_is_unreachable = c.HTTP_STATUS_ORIGIN_IS_UNREACHABLE,
    timeout_occured = c.HTTP_STATUS_TIMEOUT_OCCURED,
    ssl_handshake_failed = c.HTTP_STATUS_SSL_HANDSHAKE_FAILED,
    invalid_ssl_certificate = c.HTTP_STATUS_INVALID_SSL_CERTIFICATE,
    railgun_error = c.HTTP_STATUS_RAILGUN_ERROR,
    site_is_overloaded = c.HTTP_STATUS_SITE_IS_OVERLOADED,
    site_is_frozen = c.HTTP_STATUS_SITE_IS_FROZEN,
    identity_provider_authentication_error = c.HTTP_STATUS_IDENTITY_PROVIDER_AUTHENTICATION_ERROR,
    network_read_timeout = c.HTTP_STATUS_NETWORK_READ_TIMEOUT,
    network_connect_timeout = c.HTTP_STATUS_NETWORK_CONNECT_TIMEOUT,

    pub fn name(self: Status) [:0]const u8 {
        return std.mem.span(c.llhttp_status_name(@intFromEnum(self)));
    }

    pub fn format(self: Status, writer: anytype) !void {
        try writer.writeAll(self.name());
    }
};

test "Status: construct from llhttp_status_t" {
    const status: Status = @enumFromInt(c.HTTP_STATUS_OK);
    try std.testing.expectEqual(.ok, status);
}

test "Status: name" {
    try std.testing.expectEqualStrings("OK", Status.ok.name());
    try std.testing.expectEqualStrings("NOT_FOUND", Status.not_found.name());
    try std.testing.expectEqualStrings("INTERNAL_SERVER_ERROR", Status.internal_server_error.name());
}

test "Status: format" {
    var buf: [32]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "{f}", .{Status.not_found});
    try std.testing.expectEqualStrings("NOT_FOUND", result);
}

const IgnoreCase = struct {
    pub fn hash(self: @This(), s: []const u8) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0);

        // Process in 48-byte chunks
        var i: usize = 0;
        const chunk_size = 48;
        var lc: [chunk_size]u8 = undefined;
        while (i + chunk_size <= s.len) : (i += chunk_size) {
            inline for (0..chunk_size) |j| {
                lc[j] = std.ascii.toLower(s[i + j]);
            }
            h.update(&lc);
        }

        // Process remaining bytes
        const remaining = s.len - i;
        if (remaining > 0) {
            for (0..remaining) |j| {
                lc[j] = std.ascii.toLower(s[i + j]);
            }
            h.update(lc[0..remaining]);
        }

        return h.final();
    }
    pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
        _ = self;
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub const Headers = std.HashMapUnmanaged([]const u8, []const u8, IgnoreCase, 80);

test "Headers: put/get case insenstive" {
    var headers: Headers = .{};
    defer headers.deinit(std.testing.allocator);

    try headers.put(std.testing.allocator, "FOO", "bar");

    const val = headers.get("foo");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("bar", val.?);
}

pub const ContentType = enum(u32) {
    text,
    html,
    css,
    js,
    xml,
    json,
    yaml,
    png,
    jpeg,
    webp,
    gif,
    mp4,
    webm,
    mp3,
    wav,
    ogg,
    woff,
    woff2,
    ttf,
    unknown,

    pub fn fromContentType(value: []const u8) ContentType {
        const MAX_VALUE_LENGTH = 22;

        if (value.len == 0 or value.len > MAX_VALUE_LENGTH) {
            return .unknown;
        }

        var main_buffer: [MAX_VALUE_LENGTH]u8 = undefined;
        var main_length: usize = 0;

        while (main_length < value.len) {
            if (main_buffer[main_length] == ';') {
                break;
            }

            main_buffer[main_length] = std.ascii.toLower(value[main_length]);
            main_length += 1;
        }

        if (main_length < 8) {
            return .unknown;
        }

        const main = main_buffer[0..main_length];
        const hash = std.hash.Fnv1a_32.hash(main); 

        if ((hash == comptime std.hash.Fnv1a_32.hash("text/plain")) and std.mem.eql(u8, main, "text/plain")) return .text;
        if ((hash == comptime std.hash.Fnv1a_32.hash("text/html")) and std.mem.eql(u8, main, "text/html")) return .html;
        if ((hash == comptime std.hash.Fnv1a_32.hash("text/css")) and std.mem.eql(u8, main, "text/css")) return .css;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/javascript")) and std.mem.eql(u8, main, "application/javascript")) return .js;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/xml")) and std.mem.eql(u8, main, "application/xml")) return .xml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/json")) and std.mem.eql(u8, main, "application/json")) return .json;
        if ((hash == comptime std.hash.Fnv1a_32.hash("application/yaml")) and std.mem.eql(u8, main, "application/yaml")) return .yaml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/png")) and std.mem.eql(u8, main, "image/png")) return .png;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/jpeg")) and std.mem.eql(u8, main, "image/jpeg")) return .jpeg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/webp")) and std.mem.eql(u8, main, "image/webp")) return .webp;
        if ((hash == comptime std.hash.Fnv1a_32.hash("image/gif")) and std.mem.eql(u8, main, "image/gif")) return .gif;
        if ((hash == comptime std.hash.Fnv1a_32.hash("video/mp4")) and std.mem.eql(u8, main, "video/mp4")) return .mp4;
        if ((hash == comptime std.hash.Fnv1a_32.hash("video/webm")) and std.mem.eql(u8, main, "video/webm")) return .webm;
        if ((hash == comptime std.hash.Fnv1a_32.hash("audio/mpeg")) and std.mem.eql(u8, main, "audio/mpeg")) return .mp3;
        if ((hash == comptime std.hash.Fnv1a_32.hash("audio/wav")) and std.mem.eql(u8, main, "audio/wav")) return .wav;
        if ((hash == comptime std.hash.Fnv1a_32.hash("audio/ogg")) and std.mem.eql(u8, main, "audio/ogg")) return .ogg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("font/woff")) and std.mem.eql(u8, main, "font/woff")) return .woff;
        if ((hash == comptime std.hash.Fnv1a_32.hash("font/woff2")) and std.mem.eql(u8, main, "font/woff2")) return .woff2;
        if ((hash == comptime std.hash.Fnv1a_32.hash("font/ttf")) and std.mem.eql(u8, main, "font/ttf")) return .ttf;

        return .unknown;
    }

    pub fn fromExtension(value: []const u8) ContentType {
        if (value.len == 0) {
            return .unknown;
        }

        const name = if (value[0] == '.') value[1..] else value;
        const hash = std.hash.Fnv1a_32.hash(name);

        if (name.len < 2) {
            return .unknown;
        }

        if ((hash == comptime std.hash.Fnv1a_32.hash("txt")) and std.mem.eql(u8, name, "txt")) return .text;
        if ((hash == comptime std.hash.Fnv1a_32.hash("html")) and std.mem.eql(u8, name, "html")) return .html;
        if ((hash == comptime std.hash.Fnv1a_32.hash("css")) and std.mem.eql(u8, name, "css")) return .css;
        if ((hash == comptime std.hash.Fnv1a_32.hash("js")) and std.mem.eql(u8, name, "js")) return .js;
        if ((hash == comptime std.hash.Fnv1a_32.hash("xml")) and std.mem.eql(u8, name, "xml")) return .xml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("json")) and std.mem.eql(u8, name, "json")) return .json;
        if ((hash == comptime std.hash.Fnv1a_32.hash("yaml")) and std.mem.eql(u8, name, "yaml")) return .yaml;
        if ((hash == comptime std.hash.Fnv1a_32.hash("png")) and std.mem.eql(u8, name, "png")) return .png;
        if ((hash == comptime std.hash.Fnv1a_32.hash("jpg")) and std.mem.eql(u8, name, "jpg")) return .jpeg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("jpeg")) and std.mem.eql(u8, name, "jpeg")) return .jpeg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("webp")) and std.mem.eql(u8, name, "webp")) return .webp;
        if ((hash == comptime std.hash.Fnv1a_32.hash("gif")) and std.mem.eql(u8, name, "gif")) return .gif;
        if ((hash == comptime std.hash.Fnv1a_32.hash("mp4")) and std.mem.eql(u8, name, "mp4")) return .mp4;
        if ((hash == comptime std.hash.Fnv1a_32.hash("webm")) and std.mem.eql(u8, name, "webm")) return .webm;
        if ((hash == comptime std.hash.Fnv1a_32.hash("mp3")) and std.mem.eql(u8, name, "mp3")) return .mp3;
        if ((hash == comptime std.hash.Fnv1a_32.hash("wav")) and std.mem.eql(u8, name, "wav")) return .wav;
        if ((hash == comptime std.hash.Fnv1a_32.hash("ogg")) and std.mem.eql(u8, name, "ogg")) return .ogg;
        if ((hash == comptime std.hash.Fnv1a_32.hash("woff")) and std.mem.eql(u8, name, "woff")) return .woff;
        if ((hash == comptime std.hash.Fnv1a_32.hash("woff2")) and std.mem.eql(u8, name, "woff2")) return .woff2;
        if ((hash == comptime std.hash.Fnv1a_32.hash("ttf")) and std.mem.eql(u8, name, "ttf")) return .ttf;

        return .unknown;
    }

    pub fn toContentType(self: ContentType) []const u8 {
        return switch (self) {
            .text => "text/plain; charset=UTF-8",
            .html => "text/html; charset=UTF-8",
            .css => "text/css; charset=UTF-8",
            .js => "application/javascript; charset=UTF-8",
            .xml => "application/xml; charset=UTF-8",
            .json => "application/json; charset=UTF-8",
            .yaml => "application/yaml; charset=UTF-8",
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .gif => "image/gif",
            .mp4 => "video/mp4",
            .webm => "video/webm",
            .mp3 => "audio/mpeg",
            .wav => "audio/wav",
            .ogg => "audio/ogg",
            .woff => "font/woff",
            .woff2 => "font/woff2",
            .ttf => "font/ttf",
            .unknown => "application/octet-stream"
        };
    }
};

test "ContentType: parse from Content-Type" {
    try std.testing.expectEqual(ContentType.text, ContentType.fromContentType("text/plain"));
    try std.testing.expectEqual(ContentType.text, ContentType.fromContentType("TEXT/PLAIN"));
    try std.testing.expectEqual(ContentType.jpeg, ContentType.fromContentType("image/jpeg"));
    try std.testing.expectEqual(ContentType.unknown, ContentType.fromContentType(""));
}

test "ContentType: parse from file extension" { 
    try std.testing.expectEqual(ContentType.text, ContentType.fromExtension("txt"));
    try std.testing.expectEqual(ContentType.text, ContentType.fromExtension(".txt"));
    try std.testing.expectEqual(ContentType.jpeg, ContentType.fromExtension(".jpg"));
    try std.testing.expectEqual(ContentType.jpeg, ContentType.fromExtension(".jpeg"));
    try std.testing.expectEqual(ContentType.unknown, ContentType.fromExtension(""));
}
