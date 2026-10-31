# Getting Started

!!! warning "Draft"

    This page is a draft. Still to cover:

    - An app type with state (`http.Server(App)`), and how handlers get `*App`
    - Where to go next: routing, handlers, the client
    - Running the same example on zio

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

A handler only takes the parameters it needs. `hello` takes the `:name` part of the path as an
`http.Param`, and `index` doesn't need the request at all.
`http.Server(void)` means the server has no app state of its own; with a type there, handlers can
take a pointer to it.

The server uses `init.io`, the threaded `std.Io` implementation from the standard library. That's
fine for development, but it uses an OS thread per connection. See [Deployment](server/deployment.md) for
running it on zio.
