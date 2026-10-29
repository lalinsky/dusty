//! Replaced by an application's custom `json` module when Dusty is built with
//! `use_bundled_json=false`.

comptime {
    @compileError(
        "Dusty was built with use_bundled_json=false, but no JSON module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"json\", custom_json.module(\"json\"))",
    );
}
