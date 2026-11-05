# Zircon UI

An independent UI framework in Zig, following the [supplied framework specification](docs/specification/framework-api-v0.1.md). The name in that document, ZigGPUI, is a placeholder; the package name is `zircon_ui`.

The verified foundations implement typed generational entities, scope ownership, runtime borrowing, explicit notifications, deferred destruction, frame-local UI trees, and committed/staging frame storage. It has no native or GPU dependency. The editor comes after the framework interfaces are verified.

Use Zig 0.17.1:

```sh
./tools/zig build check
./tools/zig build counter  # inspect a declarative tree without a window
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```

`tools/zig` uses the project-local compiler when present, otherwise Zig 0.17.1 on PATH. It never changes your global compiler. With Zig 0.17.1 on PATH, ordinary `zig build check` works as well.

See the [package usage and lifetime contract](packages/zircon_ui/README.md), [implementation order](docs/implementation-plan.md), and [GPUI/NanoUI research](docs/research/gpui-and-nanoui.md). Native adapters will use direct Zig bindings, with Metal on macOS first. Neither reference framework is a dependency. Smaller/faster-than-Zed claims have not been established.
