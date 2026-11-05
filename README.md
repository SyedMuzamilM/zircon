# Zircon UI

An independent UI framework in Zig, following the [supplied framework specification](docs/specification/framework-api-v0.1.md). The name in that document, ZigGPUI, is a placeholder; the package name is `zircon_ui`.

The portable foundations implement typed generational entities, scope ownership, runtime borrowing, explicit notifications, deferred destruction, frame-local UI trees, and committed/staging frame storage. The core has no native or GPU dependency. Native graphics are tested separately. The editor comes after the framework interfaces are verified.

Read the [implementation status](docs/status.md) for what works and what remains. The framework does not yet open windows or run desktop applications through its public API.

Use Zig 0.17.1:

```sh
./tools/zig build check
./tools/zig build counter  # inspect a declarative tree without a window
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```

`tools/zig` uses the project-local compiler when present, otherwise Zig 0.17.1 on PATH. It never changes your global compiler. With Zig 0.17.1 on PATH, ordinary `zig build check` works as well.

See the [package usage and lifetime contract](packages/zircon_ui/README.md), [implementation order](docs/implementation-plan.md), and [GPUI/NanoUI research](docs/research/gpui-and-nanoui.md). Native adapters will use direct Zig bindings, with Metal on macOS first. Neither reference framework is a dependency. Smaller/faster-than-Zed claims have not been established.

On macOS with Metal, `./tools/zig build test-native` separately verifies direct Zig CoreText and GPU rendering. The tested native backend is a foundation for the next window/runtime milestone; `App.openWindow` and the editor are not implemented in this framework-first version yet.
