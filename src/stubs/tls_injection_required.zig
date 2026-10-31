//! Replaced by an application's custom `tls` module when Dusty is built with
//! `use_bundled_tls=false`.

comptime {
    @compileError(
        "Dusty was built with use_bundled_tls=false, but no TLS module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"tls\", custom_tls.module(\"tls\"))",
    );
}
