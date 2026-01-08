const std = @import("std");

pub const Server = @import("server.zig").Server;
pub const ServerConfig = @import("config.zig").ServerConfig;
pub const Router = @import("router.zig").Router;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const EventStream = @import("response.zig").EventStream;
pub const WebSocket = @import("websocket.zig").WebSocket;
pub const Status = @import("http.zig").Status;
pub const Method = @import("http.zig").Method;
pub const ContentType = @import("http.zig").ContentType;
pub const Cookie = @import("cookie.zig").Cookie;
pub const CookieOpts = @import("cookie.zig").CookieOpts;

// Client
pub const Client = @import("client.zig").Client;
pub const ClientConfig = @import("client.zig").ClientConfig;
pub const ClientResponse = @import("client.zig").ClientResponse;
pub const FetchOptions = @import("client.zig").FetchOptions;

test {
    std.testing.refAllDecls(@This());
}

// Import tests
comptime {
    _ = @import("server_test.zig");
    _ = @import("websocket.zig");
    _ = @import("client.zig");
    _ = @import("client_test.zig");
}
