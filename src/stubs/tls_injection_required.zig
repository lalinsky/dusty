//! Replaced by an application's own `tls` module when Dusty is built with
//! `tls=custom`.

comptime {
    @compileError(
        "Dusty was built with tls=custom, but no TLS module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"tls\", custom_tls.module(\"tls\"))",
    );
}
