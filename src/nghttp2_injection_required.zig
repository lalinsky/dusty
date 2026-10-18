//! Replaced by an application's custom `nghttp2` module when Dusty is built
//! with `use_http2=true, use_bundled_nghttp2=false`.

comptime {
    @compileError(
        "Dusty was built with use_bundled_nghttp2=false, but no nghttp2 module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"nghttp2\", custom_nghttp2_module)",
    );
}
