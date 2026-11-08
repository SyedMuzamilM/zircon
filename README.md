# Zircon

Zircon UI is an independent native UI framework in Zig. Zircon is a native text editor built on that framework, in separate packages. GPUI and NanoUI are architectural references, not dependencies. The [user-supplied specification](docs/specification/framework-api-v0.1.md) is preserved unchanged.

For framework development, start with the [Zircon UI API reference and remaining work](docs/zircon-ui.md) and [app setup guide](docs/zircon-ui-usage.md).

The framework now opens macOS windows through `App.openWindow` and runs them through `App.run`. It owns entity state, transactional frame trees, layout, input dispatch, focus/capture, CoreText measurement, Metal rendering, custom elements, animations, observations, typed events, and owned background jobs. Direct Zig bindings call system APIs; there are no C headers or Objective-C implementation files.

Use Zig 0.17.1 through the project-local wrapper:

```sh
./tools/zig build                  # verify and install zig-out/bin/zircon
./tools/zig build run              # open the editor
./zig-out/bin/zircon path/to/file.zig
./tools/zig build check
./tools/zig build test-native-fresh --summary all # execute native suites without cached verdicts
./tools/zig build test-editor-native # native editor and feature journeys
./tools/zig build test-language-real # optional, installed Apple clangd
# Native builds also compile the Rust extension worker with Cargo.
./tools/zig build test-native        # macOS, actual AppKit/CoreText/Metal tests
./tools/zig build counter-native     # interactive native counter with spring animation
./tools/zig build counter            # inspect a tree without a window
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```

The Linux command compiles portable tests; it does not provide a Linux native adapter. `tools/zig` uses the local compiler when present and otherwise requires Zig 0.17.1 on PATH. It does not replace the global compiler. On macOS, it applies a private [child-process isolation fix](docs/design/darwin-process-isolation.md) to the pinned standard library; direct `zig build` bypasses that fix.

Read [implementation status](docs/status.md) for tested coverage and limitations, [package usage](packages/zircon_ui/README.md), [runtime design](docs/design/runtime.md), [editor design](docs/design/editor.md), [source research](docs/research/gpui-and-nanoui.md), and the [Zed/GPUI comparison](docs/research/zed-gpui-vs-zircon-2026-11-07.md). Full Zed feature parity and performance advantages have not been established.

The [editor roadmap](docs/editor-roadmap.md) and [checklist](docs/editor-todo.md) track the remaining work. [Native verification](docs/native-verification.md) describes fresh execution and separate input-routing coverage.

The editor provides real file opening/saving, project navigation, draggable tabs and two editor panes with independent tab groups, multi-cursor editing, grouped undo/redo, clipboard/selection, lexical highlighting, find/replace, a command palette and unsaved-close protection. Integrated macOS chrome retains the native traffic lights. Settings opens in a separate child window and persists appearance/editor preferences.

A tabbed PTY terminal docks at the bottom or right. The status bar includes language selection, server status, diagnostics, and cursor information. Project and branch menus provide recent projects, branches, and stashes.

Independent Git, extension, search, Markdown and language-server packages now power real editor views. Git supports combined and working/staged diffs, staging, commits/history, continuous gutters with inline hunk expansion, blame hover cards, branch creation/switching, fetch/pull/push and stash workflows. The extension manager searches the official Zed registry and installs supported themes, icons, Tree-sitter grammars and WASM language-server adapters. Common languages bundled in Zed have separate installable providers. Project search includes unsaved buffers and opens source matches. Markdown previews update beside their source; images use the framework's retained image renderer. Stdio language servers provide versioned diagnostics and completion edits.

See the [editor guide](docs/editor-guide.md) for controls, installation paths and limits. Search excerpts currently open the original document for editing; arbitrary pane trees and broad LSP navigation/refactoring remain work. Zed extension compatibility and word wrapping are described in [the compatibility guide](docs/zed-extensions.md). The [implementation status](docs/status.md) distinguishes tested behavior from the remaining framework/editor scope.

Agent features are temporarily unavailable while editor work continues. Build the app bundle with `./tools/zig build package -Doptimize=ReleaseFast`.
