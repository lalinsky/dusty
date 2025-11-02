pub fn Router(comptime Ctx: type) type {
    _ = Ctx;

    return struct {
        const Self = @This();

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn get(self: *Self, path: []const u8, handler: anytype) void {
            _ = self;
            _ = path;
            _ = handler;
            @panic("TODO");
        }

        pub fn head(self: *Self, path: []const u8, handler: anytype) void {
            _ = self;
            _ = path;
            _ = handler;

            @panic("TODO");
        }

        pub fn post(self: *Self, path: []const u8, handler: anytype) void {
            _ = self;
            _ = path;
            _ = handler;
            @panic("TODO");
        }

        pub fn put(self: *Self, path: []const u8, handler: anytype) void {
            _ = self;
            _ = path;
            _ = handler;
            @panic("TODO");
        }

        pub fn delete(self: *Self, path: []const u8, handler: anytype) void {
            _ = self;
            _ = path;
            _ = handler;
            @panic("TODO");
        }
    };
}
