# Fluent UI migration evidence

Verified on macOS/aarch64 with Zig 0.17.1 after migrating application composition and moving literal imports into ordered file headers.

- `check-final.log`: 48/48 build steps; 383 checks passed and four explicit native-only skips. This includes 123 framework checks, the entity-view/capture/focus regression, 97 application journeys, compile-error contracts, migration-tool tests, import/fluent-caller guards, formatting and compiled documentation examples.
- `native-final.log`: 12/12 build steps and 123 native checks. These include 9 AppKit window checks, 27 framework checks, 86 application journeys and one settings journey. Counts overlap portable checks.
- `linux-final.log` and `windows-final.log`: 15/15 target-compilation steps each. These establish portable compilation, not native Linux/Windows desktop support.
- `editor-build.log`: native editor executable compilation.
- `editable-git.png` and `history.png`: fresh native captures after the fluent migration, showing direct diff editing and commit tabs in the main tab strip.

The application, settings, popovers, terminal chrome, reusable text-input control and examples now use fluent composition. The underlying framework constructors and owning custom-element construction remain explicit. New chain operations support entity views, capture handlers, focus requests, modal/drag metadata and additional typed style values. The entity-view test confirms that adding capture and focus metadata preserves text editing.

`tools/migrate_fluent.py` and `tools/hoist_zig_imports.py` operate on lexical Zig spans. Tests cover strings/comments, nested arguments, line-comment boundaries, alias collisions and repeatability. The main `check` target guards the migrated source conventions.

Two preliminary native runs failed: `native-initial.log` records three key events where the native fixture expected one, and `native-grammar-timeout.log` records a timeout waiting for a transient grammar failure. The cause was not established. Timeout diagnostics were added to the grammar fixture; `grammar-focused.log`, `native.log` and the final native suite passed. The failed logs are retained rather than counted as acceptance.

No frame-rate, memory or Zed performance comparison is claimed.
