# Zircon

Zircon UI is an independent native UI framework in Zig. Zircon is a native text editor built on that framework, in separate packages. GPUI and NanoUI are architectural references, not dependencies. The [user-supplied specification](docs/specification/framework-api-v0.1.md) is preserved unchanged.

The framework now opens macOS windows through `App.openWindow` and runs them through `App.run`. It owns entity state, transactional frame trees, layout, input dispatch, focus/capture, CoreText measurement, Metal rendering, custom elements, animations, observations, typed events, and owned background jobs. Direct Zig bindings call system APIs; there are no C headers or Objective-C implementation files.

Use Zig 0.17.1 through the project-local wrapper:

```sh
./tools/zig build                  # verify and install zig-out/bin/zircon
./tools/zig build run              # open the editor
./zig-out/bin/zircon path/to/file.zig
./tools/zig build check
./tools/zig build test-editor-native # full native editor journey
./tools/zig build test-native        # macOS, actual AppKit/CoreText/Metal tests
./tools/zig build counter-native     # interactive native counter with spring animation
./tools/zig build counter            # inspect a tree without a window
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```

The Linux command compiles portable tests; it does not provide a Linux native adapter. `tools/zig` uses the local compiler when present and otherwise requires Zig 0.17.1 on PATH. It does not replace the global compiler.

Read [implementation status](docs/status.md) for tested coverage and limitations, [package usage](packages/zircon_ui/README.md), [runtime design](docs/design/runtime.md), [editor design](docs/design/editor.md), and [source research](docs/research/gpui-and-nanoui.md). Full Zed feature parity and performance advantages have not been established.

The editor currently provides real file opening/saving, project navigation, tabs and split views, multi-cursor editing, grouped undo/redo, clipboard/selection, lexical highlighting, find/replace, a command palette and unsaved-close protection. The [expanded experience requirements](docs/specification/editor-experience.md) preserve the supplied Zed screenshots and track the next UI, extension, Git, search and content work. Those integrations are not implied by the current editing core.
