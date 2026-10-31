# Getting Started

Set up the project and add the dependency the same way as for the
[server](../server/getting-started.md#setup). Then put this into `src/main.zig`:

```zig
--8<-- "examples/fetch.zig"
```

```sh
$ zig build run
200 ok, 12337 bytes
```

`fetch` connects, sends the request, follows redirects and reads the whole body before it returns.
`response.body()` gives you that body, or null if it was empty. The response owns its memory, so
anything you got from it is only valid until `response.deinit()`.

One `http.Client` is meant to be used for the whole program. It keeps idle connections in a pool
and reuses them for later requests to the same host.
