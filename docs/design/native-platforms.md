# Native Linux and Windows plan

The editor currently has a macOS AppKit, CoreText and Metal backend. Portable Linux compilation does not count as native support. This plan keeps the frame, entity, scene, input and rollback contracts unchanged while adding real desktop adapters.

## What Zed does

The pinned GPUI source at commit `b5cd310b3b54dfc659fcc06453e6358843dfe216` selects separate macOS, Windows and Linux platform crates. The Windows path uses D3D11, DirectWrite, `WM_CHAR` and `WM_IME_*`. The Linux path has separate Wayland and X11 behavior and uses WGPU plus Cosmic Text. Zircon should keep this separation at the platform boundary, while keeping its smaller typed frame API and explicit staging rollback.

## First backend choice

Use SDL3 for the first Linux and Windows window/event backend. It supplies real X11, Wayland and Win32 windows, clipboard, UTF-8 text and composition events, IME-area updates, resize/DPI events, parent windows, dialogs, renderer reset events, and a thread-safe custom-event wake path. Pin SDL, SDL_ttf and SDL_image source revisions in the build and ship their zlib notices.

Keep the current macOS backend. SDL is a smaller way to bring up both new desktop targets, but it does not solve the whole platform task. SDL_ttf does not expose all OpenType features and cannot establish exact ligature caret behavior or the existing ligatures setting. The text system must share shaped clusters between measurement, drawing and hit testing. A complete backend should use shared HarfBuzz and FreeType shaping, with Fontconfig fallback on Linux and DirectWrite discovery on Windows, or document SDL_ttf as a limited preview mode.

The backend seam remains:

```zig
open(allocator, WindowOptions, Sink) !Surface
pump(timeout_seconds: f64) !void
wake() void
now() f64
```

`Surface.measurer()` and `Surface.present()` must use the same text cache and display-scale generation. A native path must draw all current scene primitives, preserve clip order and premultiplied image alpha, and map logical coordinates consistently into rendering, hit testing and IME rectangles.

SDL dialogs are asynchronous. Their callback can run on another thread, so they cannot be implemented by nested event dispatch while a Shell borrow is active. Add an owned request/result inbox with a window generation and deliver it through `App.wake`, like worker completions.

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

`./tools/zig build test-build -Dtarget=x86_64-linux-gnu` passes 14/14 portable compilation steps. `./tools/zig build test-build -Dtarget=x86_64-windows-gnu` now also passes 14/14 after replacing POSIX-only permission constructors with platform-aware values. No Linux or Windows native window journey has run. Docker Desktop is available locally, but its daemon is not running in this session. No Windows execution environment is linked.
