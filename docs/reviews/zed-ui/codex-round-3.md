# Codex native UI review, round 3

Reviewed application source `2faf2bb` against the installed Zed Preview 1.28.0 reference captures, using `rubric.md`. I directly inspected the native narrow palette and split captures in dark/light appearances, the extension gallery, and the changed implementation. This is my assessment, not an independent external review.

| Category | Score | Evidence and remaining gap |
| --- | --- | --- |
| Visual hierarchy and geometry | 1/2 | Thin dividers, restrained chrome, clickable paths and narrow palette containment. The header lacks semantic symbol navigation; the gutter still reserves a 52-pixel minimum and has no fold controls. |
| Color and typography | 2/2 | Dedicated text-selection colors, quieter row focus, theme-derived Markdown code colors and distinct focused split line/number. Imported styles remain limited to the documented theme vocabulary. |
| Menus and controls | 2/2 | Shared radii, caret-anchored completion, searchable pickers, keyboard hints and a wider palette whose long command labels fit at 700 pixels. |
| Editor interactions | 2/2 | Native/portable regressions cover modal editing, platform deletion, selection continuity, wrapping and split focus. The click regression verifies active-line paint moves to the other pane. This does not certify full Vim or foreground IME. |
| Existing project workflows | 2/2 | Existing Git/search/settings regressions pass. The native package journey exercises real ZLS/Pyright completion, acceptance/undo, official catalog installation, theme/icon changes and wrapping. Markdown code containment/indentation/color are asserted. |
| Total | 9/10 | Quality of the rubric's implemented workflows. Full Zed parity remains incomplete. |

Validation passed: `./tools/zig build check test-settings-native`, Linux test cross-build, ReleaseFast build, generated-icon and formatting checks. Native captures came from `/tmp/zircon-ui-review/round-3-final` and `/tmp/zircon-zed-native-round-3`; manifests verify their retained PNGs. Tests were run through the native test harness, not manual foreground typing.

No latency or frame-rate measurements were taken. Current grammar workers reparse full documents, wrapping copies its visual-row index, and Markdown parsing/layout remain synchronous and cached. LSP navigation/refactoring, semantic highlighting, arbitrary pane trees, terminal/debugger, collaboration, full Vim and Unicode-aware case folding remain gaps. See `../../zed-extensions.md` for compatibility limits. External round-3 ratings are still pending; historical ratings cannot be carried forward to this candidate.
