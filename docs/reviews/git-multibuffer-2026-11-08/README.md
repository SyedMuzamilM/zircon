# Git multibuffer delivery evidence

Verified on macOS arm64 with the project-pinned Zig 0.17.1 wrapper on November 8, 2026.

- `check.log`: `./tools/zig build check --summary all` succeeded. This includes formatting, import placement, portable application journeys, editor checks and package checks. Cached suite verdicts are identified in the log.
- `native.log`: `./tools/zig build test-editor-native --summary all` passed all 124 checks, comprising 9 native window checks, 27 framework checks and 88 application journeys. These overlap portable coverage and are not a unique-test total.
- `release.log`: `./tools/zig build package -Doptimize=ReleaseFast --summary all` completed all 60 steps, including the release executable, repository check, app bundle and ZIP. The four skipped app journeys require native rendering and are covered separately where applicable.
- `packaged-smoke.log` and `packaged.png`: the actual executable inside `artifacts/Zircon.app` started, initialized its embedded application icon, opened a native window, rendered a frame and exported the PNG successfully.
- `unified.png` and `split.png`: native Git journeys show direct source edits and saved bytes. The application menu strip is absent. Application menus are installed only in AppKit's menu bar.

The Git journey checks multiline drag selection across redraws, exact source bytes, unchanged disk before save, undo, redo, split geometry, editing the current side, refusing edits on the old side, and saving. The menu journey asserts there is no in-window application menu bar, inspects the actual AppKit menu groups and invokes File → New File through the responder chain of its own window.

The package verifier checked the ad-hoc code signature with `codesign --verify --deep --strict`, confirmed `CFBundleIconFile` names the generated ICNS, compared the bundled original logo byte-for-byte with the supplied asset, and verified executable and ZIP SHA-256 hashes against the generated manifest.

Artifacts are `artifacts/Zircon.app` and `artifacts/Zircon-macos-arm64.zip`. They contain uncommitted workspace changes and use local ad-hoc signing. The source study, package boundaries and remaining feature limits are in [the implementation notes](../../research/zed-git-multibuffer-2026-11-08.md).
