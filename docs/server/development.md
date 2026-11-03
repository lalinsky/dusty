# Development

While you work on a server, you can have it rebuilt and restarted every time you save a file, and
the pages you have open in the browser reloaded once it's back up.

The examples on this page come from
[examples/todo](https://github.com/lalinsky/dusty/tree/main/examples/todo).

## Restarting on Changes

Add a `run-server` step to `build.zig`:

```zig
const dusty = @import("dusty");

--8<-- "examples/todo/build.zig:run_server"
```

Then run the build in watch mode in one terminal, and the server in another:

```sh
$ zig build --watch -fincremental
$ zig build run-server
```

`zig build --watch` rebuilds the program after every change and installs it into `zig-out/bin`.
`run-server` runs the installed program, and restarts it whenever a new build is installed there.
It doesn't build anything itself, so it doesn't matter how the build happens. Running `zig build`
by hand works too, and the two commands can be started in either order.

When a build fails, the server that's running keeps running. When the server crashes or exits, it's
started again after the next build. Arguments after `--` are passed on to the server:

```sh
$ zig build run-server -- --port 9000
```

`-fincremental` makes the rebuilds take a fraction of a second.

`run-server` looks for the program in its own install prefix. If you build with `-p`, pass the same
`-p` to `run-server`.

The server is stopped by killing it, without a graceful shutdown, so a restart doesn't wait for the
requests in flight or the event streams that open pages hold.

## Reloading the Browser

The pages open in the browser can reload after the server restarts. Turn it on before starting the
server:

```zig
--8<-- "examples/todo/src/main.zig:dev"
```

Then put [`http.dev.script`](../../apidocs/#http.dev.script) at the end of `<body>` in your pages.
With [zt](templating.md), that's `{http.dev.script(.{})}` in the layout. Outside a template, write
it with `{f}`.

The script loads from `/_dusty/reload.js` and connects to an event stream at `/_dusty/reload`. When
the server restarts, the stream reconnects to the new process, and the page reloads.

This only happens under `run-server`, which sets the `DUSTY_DEV` environment variable for the
server. Without it, `register` adds no routes and the script tag is empty, so the same code can
stay in a production build.

### Content Security Policy

If your pages send a `Content-Security-Policy`, the script needs to be allowed by `script-src`,
and the event stream by `connect-src`. A policy that allows `'self'` for both needs nothing more.
If scripts are allowed by nonce instead, pass the nonce of the page:

```zig
<body>
    @children
    {http.dev.script(.{ .nonce = nonce })}
</body>
```

## Next Steps

- [Templating](templating.md) covers zt and layouts.
- [Deployment](deployment.md) covers running the server in production.
