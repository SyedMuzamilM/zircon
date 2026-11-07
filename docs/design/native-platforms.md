# Native Linux and Windows plan

The editor currently has a macOS AppKit, CoreText and Metal backend. Portable Linux compilation does not count as native support. This plan keeps the frame, entity, scene, input and rollback contracts unchanged while adding real desktop adapters.

## What Zed does

The pinned GPUI source at commit `b5cd310b3b54dfc659fcc06453e6358843dfe216` selects separate macOS, Windows and Linux platform crates. The Windows path uses D3D11, DirectWrite, `WM_CHAR` and `WM_IME_*`. The Linux path has separate Wayland and X11 behavior and uses WGPU plus Cosmic Text. Zircon should keep this separation at the platform boundary, while keeping its smaller typed frame API and explicit staging rollback.

## Current implementation constraints

The user requires new implementation source to be Zig. Zig bindings may call native Vulkan, windowing and font libraries. No authored C or C++ wrappers are accepted. New GPU rendering must issue GPU commands, rather than rasterizing the entire scene on the CPU and uploading one image.

Keep the current macOS Metal/CoreText backend. Evaluate Vulkan for Linux and Windows against Zed's actual platform choices. Zed uses WGPU on Linux and a separate DirectX renderer on Windows at the pinned revision. Using the same rendering architecture does not require selecting the same API on every platform.

The uncommitted SDL/Pango/Cairo prototype was removed after this requirement. Its Linux Xvfb tests demonstrated native window, shaping, caret, clipboard and event behavior, but that code is not part of the implementation. Those results do not establish current Linux or Windows support. The earlier SDL debug-font draft was also discarded.

SDL3 remains a possible window/event library through Zig declarations. It must not own the scene rasterizer. Native text libraries may shape and rasterize glyphs into a GPU atlas, while the GPU draws the text quads. Measurement, hit testing and drawing must share the same shaped cluster positions and font generation. SDL_ttf's feature limits still prevent promising the existing ligature setting through that API alone.

The Vulkan evaluation must establish Zig 0.17.1 bindings, loader/surface creation, swapchain rebuilds, synchronization, uploads, atlas lifetime, clipping, images and premultiplied alpha, device loss, DPI and packaging. Shader generation is part of the Zig-only design decision. Do not introduce authored GLSL, HLSL or WGSL files without resolving that constraint.

The platform seam remains:

```zig
open(allocator, WindowOptions, Sink) !Surface
pump(timeout_seconds: f64) !void
wake() void
now() f64
```

CPU frame commit still follows successful validation and GPU submission staging. Renderer resets and failed presentation must schedule bounded retries without replacing the committed handlers or sleeping forever. Native dialog callbacks require an owned request/result inbox with a window generation, delivered through the application wake path.

## Findings retained from the discarded prototype

- Pango's signed 32-bit coordinates use 1/1024-pixel units. Very long unwrapped lines can overflow even below a 1 MiB text limit. Bound or segment geometry before publication.
- Fontconfig application fonts require an explicit per-map configuration. Adding temporary fonts through the process-global configuration can poison later maps after the files disappear.
- Color glyphs can ignore solid-source alpha. GPU color-glyph sampling must multiply inherited opacity, just like images and monochrome text.
- Image sampling must clamp at texture edges. Transparent border sampling changes both opacity and edge colors.
- A bounded event drain must stop before polling the next event, including ignored-event paths.
- A device-reset event must invalidate idle windows. A retry needs a deadline that affects the native wait.

These are requirements for the replacement, not evidence that it has been implemented.

## Platform work outside the window

- Extract terminal transport from `terminal.zig`. Keep the shared terminal parser/model. Use POSIX PTYs on Linux and ConPTY on Windows.
- Replace macOS application paths with XDG paths on Linux and known application-data paths on Windows. Preserve the recovery/session path contract.
- Replace `/usr/bin/open` with an OS service for opening URLs and files.
- Select ImageIO on macOS and SDL_image or WIC on the other targets. Keep bounded dimension and byte preflight.
- Add native menu/dialog/file-drop and accessibility adapters. SDL does not provide Zircon’s accessibility tree. Linux needs AT-SPI; Windows needs UI Automation.
- Keep Ctrl and Super distinct in the common keymap. Do not map Linux/Windows Ctrl to macOS Command in the platform adapter.
- Add device/presentation reset handling. A failed present must schedule a retry or expose a recoverable state so a dirty window cannot sleep forever.
- Add platform-specific titlebar/chrome metrics. macOS traffic lights and integrated titlebar behavior must not leak into Windows or Linux.

## Acceptance gates

The first native vertical slice is a visible counter and editor window on Linux and Windows. It must render shaped Unicode text, rectangles, rounded rectangles, lines and images; agree on caret and hit testing; accept text, clipboard and resize/DPI events; process worker wakeups; and close cleanly. Xvfb or Weston in a Linux container proves functional native execution, not hardware performance or every compositor’s IME behavior. Windows remains unverified until a real Windows environment drives the same journey.

Then add PTY transport, dialogs, file paths, IME, accessibility and packaging. Cross-compilation is a gate against accidental platform imports. It is evidence of target compatibility, not evidence that a desktop user can run the editor.

## Current evidence

`./tools/zig build test-build -Dtarget=x86_64-linux-gnu` passes 14/14 portable compilation steps. `./tools/zig build test-build -Dtarget=x86_64-windows-gnu` now also passes 14/14 after replacing POSIX-only permission constructors with platform-aware values. No retained Linux or Windows backend has passed a native window journey. The discarded C/Cairo prototype passed Linux checks before removal and does not count as current support. Docker Desktop currently provides a running Linux/aarch64 daemon. An earlier session observed it stopped; that observation is superseded. No Windows execution environment is linked.
