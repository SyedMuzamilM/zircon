# Zircon extensions

A UI-independent local contribution registry for themes, icon themes, lexical language definitions and language-server configurations. It loads versioned JSON data and packaged assets. It does not load native plugin code, run server executables or implement Zed/WASM extension compatibility.

```zig
var registry = try extensions.Registry.init(allocator, io, extension_home);
defer registry.deinit();
_ = try registry.install("path/to/dev-extension");
var snapshot = registry.snapshot();
defer snapshot.deinit();
const theme = snapshot.resolveTheme("oxide-night");
const language = snapshot.languageForPath("script.py");
try registry.setEnabled("org.zircon.oxide", false);
// The retained snapshot still owns its previous values and PNG bytes.
```

Registry operations run on their creator thread. Snapshots are move-owned handles; call `clone()` to retain another reference and `deinit()` once per reference, on that thread. Contribution strings, arrays, returned pointers and PNG bytes borrow a snapshot. `install()` returns an ID borrowed from the effective registry generation, valid until the next mutation; copy it or retain a snapshot before keeping it. Disabling or removing an extension publishes a new generation and does not invalidate retained frames. Consumers should choose their built-in fallback when a resolver returns null.

## Format and example

The real [Oxide example](examples/oxide/extension.json) contributes theme `oxide-night`, icon theme `oxide-symbols`, Python lexical rules and a `zls` server configuration. Install its directory to exercise local contributions. The example does not install ZLS itself. A configured language-server process belongs to the host's separate protocol implementation.

`extension.json` has `schema_version: 1`, lowercase ASCII `id`, display `name`, `version`, optional `description` and `contributes`. Contribution IDs are unique across installed packages, including disabled packages. Unknown schema fields are rejected instead of silently ignored. Version is a bounded display string; this registry does not resolve dependency versions or update feeds.

- `themes` contains `{id,name,colors,syntax}`. Color strings use `#RRGGBB` or `#RRGGBBAA`; omitted tokens inherit documented defaults in `manifest.zig`. Resolved `Color.rgba` packs red in the highest byte and alpha in the lowest. UI tokens are document, chrome, sidebar, panel, line, text, muted, accent, selected, warning and primary. Syntax tokens are plain, keyword, string, number, comment, punctuation and builtin.
- `icon_themes` contains `{id,name,files,extensions,folders,default_file,default_folder}`. Each mapping is `{key,icon}`. An icon has exactly one of `{symbol:"Py"}` or `{png:"icons/python.png"}`. File/folder mappings use exact basename; extension matching ignores ASCII case and an optional leading dot. Defaults are `·` and `▸`. PNG encoded bytes belong to the retained snapshot. Header/dimension limits are checked here; complete image decoding remains the renderer's responsibility.
- `languages` contains `{id,name,extensions,filenames,keywords,line_comment,block_comment,string_delimiters}`. Extensions ignore ASCII case and an optional leading dot; filenames are exact basenames. Block comments use `{start,end,nested}`. String delimiters are a set drawn from single quote, double quote and backtick. These are lexical contribution rules, not parser grammars or semantic highlighting.
- `language_servers` contains `{id,languages,command,args}`. Commands and arguments remain separate strings; the registry never interpolates a shell command or starts a process.

`Snapshot.installed()` reports actual managed metadata and activation. `extension(id)`, `resolveTheme(id)`, `resolveIconTheme(id)`, `languageForPath(path)` and `serverForLanguage(language_id)` expose typed values. Resolution considers enabled packages in deterministic extension-ID order. There is no remote marketplace, fabricated download count or automatic executable download.

## Installation and persistence

`Registry.init` creates/canonicalizes the supplied managed home and reads installed directories plus `state.json`. An invalid installed manifest/state file is returned as an error for the host to display. Installation validates the source, copies to a hidden staged directory, validates the copy, publishes its managed directory without clobbering another package, and atomically writes activation before replacing the effective snapshot. Any failure retains the previous effective snapshot and rolls back the new managed directory. Existing extension IDs return `ExtensionAlreadyInstalled`; updating currently requires explicit remove/install.

Enable/disable validates a complete candidate and writes a sibling temporary activation file, flushes it, and atomically replaces `state.json` before publication. Remove first renames only its managed directory to hidden trash and restores it if candidate loading or activation fails. Retained snapshots keep copied asset bytes. A failure to delete inert hidden trash after successful publication does not reactivate the package. Registry homes have a single writer; separate Registry instances must not mutate one home concurrently.

Bundles contain only ordinary files/directories, at most 16 MiB total, 1,024 entries and 16 directory levels. There may be at most 128 installed packages. A manifest is at most 1 MiB. PNG assets are at most 8 MiB encoded, 8,192 pixels on either dimension and 16 million pixels total. Absolute contribution paths, `.`/`..`, empty path segments, backslashes and NUL are rejected. All bundle symlinks are refused. Source directories cannot contain the managed home. Sources must remain stable while being installed; this is not a sandbox against another process changing files concurrently.

## Verification

Run from the repository root with Zig 0.17.1:

```sh
./tools/zig build --build-file packages/zircon_extensions/build.zig check
./tools/zig build --build-file packages/zircon_extensions/build.zig test-build -Dtarget=aarch64-linux-gnu
```

Tests use real temporary directories and activation files. They verify contribution resolution, disable/reopen state, retained snapshots/assets after removal, invalid schemas/JSON/paths, symlink refusal, duplicate rollback, missing assets, failure retention and allocation cleanup. Rendering colors/icons and starting configured language servers are host integration checks, not implied by registry tests.
