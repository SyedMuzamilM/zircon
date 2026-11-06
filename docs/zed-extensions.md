# Zed extensions and language support

Zircon now searches the official [zed-industries/extensions registry](https://github.com/zed-industries/extensions). The catalog reads every registry ID, including those beyond the API's 1,000-result cap. The API enriches names, descriptions and capability metadata. The native verification on 2026-11-06 saw 1,585 official entries; this count can change.

Open Extensions, select **All Zed extensions**, search, and choose Install. Installed packages can be enabled, disabled, removed or updated. Theme/icon variants are selectable in Settings. A language label in the status bar opens a catalog search for the current file. Known suffixes and special filenames translate to language names, including `.ex` → Elixir, `.tf` → Terraform, `.cs` → C#, and Dockerfile. Files without installed support offer an installation hint. Downloads and server setup run in worker jobs, and failures remain visible instead of pretending installation succeeded.

The manager also lists 13 common language providers because Zed includes these in its core rather than publishing them all as registry extensions: Python, JavaScript/JSX, TypeScript, TSX, Rust, Go, C, C++, CSS, HTML, JSON, YAML and Bash. Their Tree-sitter parsers and highlight queries come from pinned upstream crates. Node.js/npm are required for Pyright, TypeScript, web, YAML and Bash servers. Go is required to install gopls; C/C++ uses clangd on PATH. Rust uses rust-analyzer on PATH or an upstream release. Official Zig support uses the official extension's own ZLS installation hook.

## What works

| Contribution | Implementation |
| --- | --- |
| Catalog | All official registry IDs, searchable names/descriptions, real versions, installed/update state, virtualized results |
| Theme families | Zed JSON surfaces, player selection and syntax colors mapped to Zircon's current tokens; multiple variants available in Settings |
| File icon themes | File suffix/stem and directory mappings; original SVG assets retained and rasterized with resvg into package-local cached PNGs |
| Languages | `languages/*/config.toml`, file names/suffixes, multipart suffixes and protocol language IDs |
| Grammar highlighting | Actual packaged Tree-sitter WASM parser plus `highlights.scm`; source spans checked for UTF-8 boundaries and document revision |
| Language servers | Component-model WASM `init-extension`, command, initialization options and workspace configuration exports |
| Common host imports | Worktree root/read/which/environment, platform, GitHub release lookup, bounded downloads/extraction, HTTPS fetch, npm lookup/install and declared `process:exec` hooks |
| LSP client | Initialize, open/change/close, UTF-16 positions, diagnostics, completion/edit acceptance, cancellation, workspace configuration and registration/progress acknowledgments |
| Local development | Existing Zircon JSON bundles or Zed TOML bundles; TOML conversion happens in a managed staging copy |
| Word wrap | Settings → Word wrap or Option-Z; cached visual rows, UTF-8 boundaries, source-length selection, vertical/pointer navigation and Git/blame geometry |

Zircon's own SVG controls continue to come from `assets/icons`. Imported icon themes use their own package assets and retain the original files. Registry installation publishes a validated managed copy. Updates preserve activation and old snapshots and restore the previous package if persistence fails. Limits are 128 MiB per package, 16,384 entries, 16 directory levels, a 16 MiB converted manifest and 2,048 installed packages. Repeated PNG references share encoded bytes in a generation.

## Limits

This is working interoperability, not universal Zed extension parity. Catalog visibility does not certify every extension. Unsupported-only packages cannot be installed; known unsupported capabilities are marked in the UI. Mixed packages can supply their supported themes/languages while reporting additional unsupported features.

- AI agents, context servers, debug adapters/locators, slash commands and snippets are not implemented.
- WASM imports not implemented by the host return an explicit error. HTTP response streaming, extension label customization, and all historical/current API combinations have not been certified.
- Query injections and per-language editor behaviors beyond the imported association/comment rules are not implemented. Tree-sitter highlights map into Zircon's seven token categories; semantic tokens remain absent.
- Theme-specific font styles and the full Zed color-token vocabulary are not represented. Expanded/collapsed folder variants and chevron mappings are not fully represented by the current icon model.
- LSP hover, definition/reference navigation, rename, formatting and code actions remain outside the current protocol UI. Completion opens after typing a member-access dot, or can be requested with Control-Space; snippet completions remain unsupported.
- npm install scripts are disabled. Extensions requiring those scripts may need a user-installed binary. Native subprocess hooks require a matching manifest `process:exec` capability; no shell command is synthesized by Zircon.
- Grammar execution and response parsing run off the UI thread. Work is coalesced after 80 ms of editing inactivity, with one request per visible document in flight. It currently starts a worker process and reparses the document, up to 8 MiB, rather than maintaining an incremental parse tree. No latency benchmark is claimed.
- Wrapping reuses unchanged maps and reshapes changed lines. It still copies the visual-row index after edits and scans document lines on initial layout or width/font changes. This is not Zed's background sum-tree wrap map. Full grapheme/bidi behavior remains incomplete. Lines over 64 KiB retain the existing oversized-line display policy.
- Remote catalog search needs network access. Download/update requests are explicit user actions. Package compatibility was exercised with Zig, Catppuccin and Catppuccin Icons; not every registry package was downloaded or executed.

Markdown fenced code also wraps long words within the preview, preserves indentation and follows the current editor token colors. This removes the previously reviewed clipping and light-theme token-color defects.

## Configure a server

Settings JSON preserves unknown fields. The worker reads Zed-style `lsp` settings. For example:

```json
{
  "soft_wrap": "editor_width",
  "lsp": {
    "pyright": {
      "binary": {
        "path": "/absolute/path/to/pyright-langserver",
        "arguments": ["--stdio"]
      },
      "settings": {}
    }
  }
}
```

Bundled provider keys are `pyright`, `typescript`, `rust-analyzer`, `gopls`, `clangd`, `html`, `css`, `json`, `yaml` and `bash`. Official WASM adapters use their own declared server keys, such as `zls`. Run **Language: restart servers** after changing server settings or retrying a failed setup.

## Build and verify

Native builds now require Cargo/Rust as well as the pinned Zig toolchain. `./tools/zig build` installs `zircon-extension-host` beside `zircon`; keep both executables together. `./tools/zig build extension-host` builds the worker separately. The Rust dependency graph is locked; it does not compile Zed's GPL application crates.

```sh
./tools/zig build check test-settings-native
cargo test --manifest-path tools/zed-extension-host/Cargo.toml --release --locked
cargo clippy --manifest-path tools/zed-extension-host/Cargo.toml --release --locked -- -D warnings
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```

The opt-in `verify-zed-extensions` target uses disposable files/preferences and real downloaded packages. Prepare a fixture directory with converted `zig`, `catppuccin`, `catppuccin-icons` packages and a `python` provider using the worker's `install` command. Run with a new output directory:

```sh
./tools/zig build verify-zed-extensions \
  -Dzed-fixtures=/absolute/fixtures \
  -Dzed-output=/tmp/zircon-zed-native-new
```

The journey verifies actual grammar spans, ZLS and Pyright initialization/completions, automatic ZLS completion on typing a dot, completion acceptance and undo, highlight refresh after edits, theme/icon application, wrapped rendering, disabling Zig, official catalog results, and an Install button downloading another theme. It uses hidden native windows, not a browser mockup. Screenshots are under [extensions evidence](reviews/extensions/evidence/). Unit tests also exercise every bundled grammar query, archive traversal rejection, upgrade rollback, PNG deduplication and incremental wrap mappings. These establish behavior, not universal package compatibility or foreground IME/VoiceOver acceptance.

## Sources inspected

The [official development guide](https://zed.dev/docs/extensions/developing-extensions) was fetched directly after Context7 returned an invalid API-key error. Source comparison used Zed commit `4a6121bb0f10c6e8037b741b7dc0a4cd639ae289`:

- [Extension manifest](https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/extension/src/extension_manifest.rs)
- [WASM host](https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/extension_host/src/wasm_host.rs)
- [Extension WIT](https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/extension_api/wit/since_v0.6.0/extension.wit)
- [Wrap map](https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/display_map/wrap_map.rs)
- [Bundled languages](https://github.com/zed-industries/zed/tree/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/languages/src)
