# Getting Started

Dusty needs Zig 0.16 or 0.17. We'll start from an empty project.

## Setup

Create the project and add Dusty as a dependency:

```sh
$ zig init
$ zig fetch --save "git+https://github.com/lalinsky/dusty#v0.5.0"
```

Then open `build.zig` and add the module to your executable, after the `exe` definition:

```zig
const dusty = b.dependency("dusty", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("dusty", dusty.module("dusty"));
```

## Hello World

Put this into `src/main.zig`:

```zig
--8<-- "examples/hello_world.zig"
```

Now build and run it:

```sh
$ zig build run
```

Then try it from another terminal:

```sh
$ curl http://127.0.0.1:8080/hello/zig
Hello, zig!
```

Both routes go to `hello`. On `/` there is no `name` parameter, and it falls back to `world`.
`http.Server(void)` means the server has no app state of its own; with a type there, handlers can
take a pointer to it.

The server uses `init.io`, the threaded `std.Io` implementation from the standard library. That's
fine for development, but it uses an OS thread per connection. See [Deployment](deployment.md) for
running it on zio.
