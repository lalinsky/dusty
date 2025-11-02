const std = @import("std");

const http = @import("http.zig");

pub const Request = struct {
    method: http.Method,
};
