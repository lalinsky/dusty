const std = @import("std");
const http = @import("../http.zig");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

pub const Config = struct {
    origin: []const u8,
    headers: ?[]const u8 = null,
    methods: ?[]const u8 = null,
    max_age: ?[]const u8 = null,
};

origin: []const u8,
headers: ?[]const u8,
methods: ?[]const u8,
max_age: ?[]const u8,

const Cors = @This();

pub fn init(config: Config) !Cors {
    return .{
        .origin = config.origin,
        .headers = config.headers,
        .methods = config.methods,
        .max_age = config.max_age,
    };
}

pub fn execute(self: *const Cors, req: *Request, res: *Response, executor: anytype) !void {
    try res.header("Access-Control-Allow-Origin", self.origin);

    if (!std.mem.eql(u8, self.origin, "*")) {
        try res.header("Vary", "Origin");
    }

    if (req.method != .options) {
        return executor.next();
    }

    if (req.headers.get("Access-Control-Request-Method") == null) {
        return executor.next();
    }

    if (self.headers) |headers| {
        try res.header("Access-Control-Allow-Headers", headers);
    }
    if (self.methods) |methods| {
        try res.header("Access-Control-Allow-Methods", methods);
    }
    if (self.max_age) |max_age| {
        try res.header("Access-Control-Max-Age", max_age);
    }

    res.status = .no_content;
}
