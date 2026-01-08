pub const ServerConfig = struct {
    timeout: Timeout = .{},
    request: Request = .{},

    pub const Timeout = struct {
        /// Maximum time (ms) to receive a complete request
        request: ?u64 = null,
        /// Maximum time (ms) to keep idle connections open
        keepalive: ?u64 = null,
        /// Maximum number of requests per keepalive connection
        request_count: ?usize = null,
    };

    pub const Request = struct {
        /// Maximum size (bytes) for request body
        max_body_size: usize = 1_048_576, // 1MB default
        /// Buffer size (bytes) for reading request headers
        buffer_size: usize = 4096,
        /// Maximum number of headers allowed in a request
        max_header_count: usize = 32,
        /// Maximum number of route parameters (e.g., /user/:id/:action)
        max_param_count: usize = 8,
        /// Maximum number of query string parameters
        max_query_count: usize = 32,
        /// Maximum number of form fields (application/x-www-form-urlencoded)
        max_form_count: usize = 32,
        /// Maximum number of multipart form fields
        max_multiform_count: usize = 32,
    };
};
