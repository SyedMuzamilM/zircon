# Zed extension worker

Build with `cargo build --release --locked`, or use `./tools/zig build extension-host` from the repository root to install beside the editor. Native editor builds include it. The [compatibility guide](../../docs/zed-extensions.md) explains supported contributions and remaining limits.

Requests are argv-based, with one JSON response on stdout and errors on stderr. `highlight` reads UTF-8 source on stdin. The app owns worker jobs and rejects stale document/registry generations before applying results.

```sh
zircon-extension-host catalog python
zircon-extension-host install zig /new/staging/zig
zircon-extension-host install language-python /new/staging/python
zircon-extension-host import-copy /source/zed-extension /new/staging/copy
zircon-extension-host resolve /package/extension.wasm zls /project /managed/work [/settings.json]
zircon-extension-host resolve-builtin pyright /project /managed/work [/settings.json]
zircon-extension-host highlight /package/grammars/zig.wasm zig /package/languages/zig/highlights.scm < source.zig
```

`import` converts an existing disposable package in place; the application uses `import-copy` so development sources stay untouched. Catalog installation checks package ID/version against the source registry before conversion. Original package contents and notices remain in the managed package. SVG theme assets are rendered once during conversion; stock editor SVGs continue to use root `assets/icons`.

The runtime executes WebAssembly components with instruction and memory limits and an extension-local WASI directory. Network/download hooks and supported native setup operations have size/time bounds. `process:exec` uses the manifest's exact/wildcard argv capability; unknown APIs fail explicitly. This worker is not a universal Zed host or a sandbox for a language-server binary.

Rust tests execute every bundled grammar query and check path rejection and provider searches. The opt-in native journey in `tools/verify_zed_extensions.zig` additionally tests real packages and servers. Keep `Cargo.lock` committed.
