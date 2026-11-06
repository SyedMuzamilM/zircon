# Buffer controls verification

Native captures from 2026-11-06 accompany the icon-theme, search, gutter and settings fixes. Each PNG's dimensions and SHA-256 are in [manifest.json](manifest.json). These supplement the earlier reviews; their scores describe earlier candidates.

| Behavior | Evidence |
| --- | --- |
| Find/replace below breadcrumbs, regex options, result counter and rounded input borders | [Dark search](zircon-buffer-find.png), [760 × 500 light search](zircon-buffer-find-light-narrow.png) |
| Wider gutter, disclosure controls after line numbers, source rows hidden after clicking | [Hover](zircon-gutter-hover.png), [Collapsed](zircon-gutter-folded.png) |
| Continuous 6-pixel Git marker at the left boundary and inline removed/current rows | [Expanded hunk](zircon-inline-hunk.png) |
| Settings icon picker updates both file tree and tab | [Switched theme](zircon-icon-theme-switched.png) |
| Delayed tooltip remains inside the viewport | [Tooltip](zircon-icon-tooltip.png) |
| Nested settings navigation and live gutter preferences in both appearances | [Dark settings](zircon-settings-gutter-dark.png), [Light settings](zircon-settings-gutter-light.png) |

The native journeys also assert query/replacement typing, Tab focus transfer, case/whole-word toggles, Unicode regex capture replacement, undo, invalid-regex recovery, Command-G after edits and tab changes, revealing hidden search matches, settings persistence and live propagation. Editor tests cover fold mapping through edits, wrapped rows and Vim vertical navigation. The filename-stem PNG regression and settings picker regression both failed before their fixes.

Validation passed:

```sh
./tools/zig build check test-settings-native --summary all
./tools/zig build test-build -Dtarget=aarch64-linux-gnu --summary failures
cargo test --release --locked --manifest-path tools/zed-extension-host/Cargo.toml
cargo clippy --release --locked --manifest-path tools/zed-extension-host/Cargo.toml -- -D warnings
python3 tools/generate_icons.py --check
git diff --check
```

Two portable tests skip native-only image checks; the native suite executes those paths. Screenshots were inspected directly against the supplied Zed references. Folding is currently indentation-based, with revision caching and an 8 MiB source limit. Buffer matching uses bounded worker requests and Rust regex syntax. No frame-rate or latency benchmark was measured in this pass.
