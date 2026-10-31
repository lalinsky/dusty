# Requests

`http.Request` has the method and URL, the `headers`, the parsed `query` string, and the route's
`params`:

```zig
const page = req.query.get("page") orelse "1";
const agent = req.headers.get("User-Agent");
```

The body is only read from the connection when the handler asks for it, with `req.body()`,
`req.formData()`, `req.multiFormData()` or `req.json(T)`. A gzip or deflate body is decoded on the
way, and anything over `max_body_size`, 1 MiB by default, is rejected with a 413.
`req.cookies()` parses the `Cookie` header.

Allocate anything that only lives for the request from `req.arena`. It's reset after the response
has been sent.
