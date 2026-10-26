//! Replaced by an application's custom `msgpack` module when Dusty is built with
//! `use_bundled_msgpack=false`.

comptime {
    @compileError(
        "Dusty was built with use_bundled_msgpack=false, but no MessagePack module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"msgpack\", custom_msgpack.module(\"msgpack\"))",
    );
}
