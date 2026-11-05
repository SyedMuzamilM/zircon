# Zircon UI

An independent UI framework in Zig, guided by the [framework specification](docs/specification/framework-api-v0.1.md). The first milestone is a GPU-independent entity runtime and headless harness. The editor follows the framework, as described in the [implementation plan](docs/implementation-plan.md).

The implementation targets Zig 0.17.1. Native system integration will use direct Zig bindings, with Metal on macOS first. NanoUI and GPUI are architectural references, not dependencies.

This repository is under construction. See the implementation plan for milestone acceptance criteria; unverified or proposed APIs are not advertised as working features.
