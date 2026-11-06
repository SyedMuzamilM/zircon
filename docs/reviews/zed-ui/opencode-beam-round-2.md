# Zircon native editor UI review — OpenCode Beam round 2

Reviewer: opencode-beam (independent). Target: commit `335a022` in `/Users/syedmuzamilm/work/expirements/zigpui` vs installed Zed Preview 1.28.0. Rubric: `docs/reviews/zed-ui/rubric.md` + `docs/reviews/zed-ui/inspection.md`. Evidence: `docs/reviews/zed-ui/evidence/manifest.json` (35 PNGs). No app/source/evidence changes, no tests run, no desktop driven, no delegation.

## Evidence method and limits

- I did **not** directly view PNGs: this model reports that it cannot read image inputs (`read` on PNGs returns "does not support image input"). I used OCR (`tesseract 5.5.2`) and pixel sampling (`ImageMagick 7.1.2`) on the retained PNGs, plus source and test inspection.
- I did not run `zig build`, native tests, or the capture runner. Validation claims (`zig build check test-settings-native`, 57 native tests, Linux cross-build, ReleaseFast, SVG asset check) are taken from `inspection.md` and the user's task statement, not independently executed.
- Native tests are hidden-AppKit-window tests; they do not establish foreground IME or VoiceOver acceptance. Screenshots do not prove frame rate, latency, responsiveness, or accessibility.
- Markdown rendering is coalesced/cached/background-parsed (`apps/zircon/src/views/markdown.zig`: `cachedLayout`, `Generation` refcount, `layout_builds`); incremental/streaming event layout is **not** established by source or tests.
- Zircon frames omit AppKit traffic lights by capture design; their presence is checked in `apps/zircon/tests/native_journey.zig`, not by these PNGs. This is not a Zircon defect.

## Scores

| Category | Score |
| --- | --- |
| 1. Visual hierarchy and geometry | 1 |
| 2. Color and typography | 1 |
| 3. Menus and controls | 2 |
| 4. Editor interactions | 2 |
| 5. Existing project workflows | 2 |
| **Total** | **8 / 10** |

Visual categories (1–2) are deliberately conservative because I could not directly inspect the screenshots; code, OCR, and pixel sampling support the implemented improvements but do not replace visual review. I did not inflate to meet the 9/10 target reported by the implementing agent.

## 1. Visual hierarchy and geometry — 1

Implemented and test-pinned in source:
- Titlebar, tabs, tree, gutter, status bar, thin 5px drag target with 1px paint (`apps/zircon/src/view.zig:135-137`), adjacent tab shared border (`apps/zircon/src/views/chrome.zig:37`), sidebar shrink to 120px (`apps/zircon/tests/workspace_polish_tests.zig:75-88`), split-menu clamping (`workspace_polish_tests.zig:152-177`), pane containment for all four split directions (`workspace_polish_tests.zig:48-74`).
- Clickable path breadcrumbs and a `Line {n}` control are implemented (`chrome.zig:83-102`, `Shell.onBreadcrumb` at `shell.zig:307-330`), with pane-focus test (`workspace_polish_tests.zig:241-259`).
- Indent guides are painted per tab stop (`packages/zircon_editor/src/canvas.zig:126-138`).
- Horizontal overflow thumb is painted from visible-line widths (`canvas.zig:206-212`), with editor test `packages/zircon_editor/tests/all.zig:693-714`.

Remaining defects:
- Breadcrumbs are path/line only, not semantic symbol breadcrumbs; `fileHeader` shows bare path segments (`chrome.zig:83-96`), whereas Zed shows symbol context (`zed-dark-editor.png`).
- Markdown fenced code uses `wrap = false` (`apps/zircon/src/views/markdown.zig:391-396`) and the preview canvas has only a vertical scrollbar (`markdown.zig:468-472`); long code lines clip at narrow widths without a horizontal affordance.
- Fold chevrons are not present in Zircon captures.

## 2. Color and typography — 1

Implemented and supported by code/pixel sampling:
- Distinct text-selection colors: dark `0x3D5275`, light `0xC6D2F5`; inactive selection `0x33425A` / `0xE0E5F1`; active line `0x2F343E` / `0xEEF1F5`; selected rows neutral `0x3B414D` / `0xE2E5ED` (`packages/zircon_editor/src/theme.zig:11-18`, `apps/zircon/src/theme.zig:22-23,33`).
- Selection bands include newline cells and fill full line height (`canvas.zig:140-146`), with tests `packages/zircon_editor/tests/all.zig:511-534` and `679-686`.
- Extension themes use `applySelection`, deriving row/hover fills separately from text selection (`apps/zircon/src/theme.zig:26-32`, `services/extensions.zig:31`, `settings/view.zig:526`).
- Light code tokens were strengthened (`theme.zig` light: keyword `0x8A2F94`, string `0x3C7E35`, number `0x9C4E00`, comment `0x68717C`); pixel sample on `zircon-light-editor.png` at the `const` keyword returned `0x9647A0`, confirming a visible non-background token color.

Not fully verified visually (no direct image inspection): icon alignment/readability across all surfaces, exact light/dark surface separation, and whether light tokens now match Zed's One Light contrast. I therefore withhold a 2 here.

## 3. Menus and controls — 2

- Compact command palette with fixed 38px query height, 30px rows, outside dismissal, and navigation/confirmation hints (`apps/zircon/src/view.zig:171,194,226`; test `workspace_polish_tests.zig:207-222`).
- Searchable font and theme pickers with filtering (`settings/view.zig:480-506`, `view.zig:294-300`), shared radii (`components.zig` `control_radius`/`popover_radius`), popover anchoring/clamping (`workspace_polish_tests.zig:152-177`).
- Completion anchors to committed caret and supports Up/Down (`view.zig:44-49`, `actions.zig:709-718`; bounds test `experience_tests.zig:308-323`).
- New captures confirm menus/pickers render: `zircon-dark-workspace-menu.png`, `zircon-dark-split-menu.png`, `zircon-dark-font-picker.png`, `zircon-dark-theme-picker.png`, `zircon-dark-search.png` (OCR verified).
- Limit: command catalog breadth (72 commands in `commands.zig`) remains smaller than Zed's; this is treated as feature breadth rather than control mechanics.

## 4. Editor interactions — 2

Supported by passed native tests and source (not independently run):
- Ordinary UTF-8 input, composition transactions, macOS deletion (`native_journey.zig:18-28,155-194,296-300`).
- Continuous multiline selection (`canvas.zig:140-146`; `packages/zircon_editor/tests/all.zig:511-534`).
- Vim modes/operators and slash search returning to Normal (`native_journey.zig:229-313`; `workspace_polish_tests.zig:179-205`).
- Split resizing/focus (`workspace_polish_tests.zig:48-74`; `view_tests.zig:138-155`).
- Both pane canvases stay inside pane bounds (`view.zig:83-108`).

Unverified/absent: foreground IME acceptance, VoiceOver, soft wrapping, grapheme motion, and advanced Vim. These are outside this rubric score's proof but remain parity gaps.

## 5. Existing project workflows — 2

- Git: commit is disabled until staged changes and a nonblank message exist, and during operations/conflicts (`git_sidebar.zig:53-66`; test `experience_tests.zig:399-403`). Captures show disabled state (`zircon-dark-git.png`, `zircon-light-git.png`).
- Combined diff with intraline highlights (`git_diff.zig:143-174`, `annotations.zig:94-108`), width-dependent summaries (`git_diff.zig:55`), blame hover (`editor_git.zig`).
- Project search capture shows 8 matches across 2 files/buffers (`zircon-dark-search.png`, OCR verified); search service and find/replace overlays implemented (`views/search.zig`, `view.zig:206-214`).
- Markdown preview capture renders headings, lists, code, tables, and images (`zircon-dark-markdown.png`, OCR verified); preview uses cached layout and image reuse (`markdown.zig`).
- Completion capture from native installed-server journey exists (`zircon-dark-completion.png`), at 1200×760 (not a matched Zed screenshot).
- Settings: searchable theme/font pickers, appearance persistence, and light-search initialization fix (`settings/view.zig`, `settings_tests.zig`).

Remaining gaps within/around this rubric: settings has only 4 categories vs Zed's broader catalog; no hunk staging or conflict-resolution editor; Markdown incremental streaming is not established (only coalesced/background parsing and caching). These do not override the tested workflows above but should remain visible in any feature-parity assessment.

## Concrete defects with locations

1. `apps/zircon/src/views/chrome.zig:83-96` — breadcrumbs are path/line only; no semantic symbol context.
2. `apps/zircon/src/views/markdown.zig:391-396,468-472` — fenced code does not wrap and preview has no horizontal scroll affordance.
3. `apps/zircon/src/settings/view.zig:9` — only 4 settings categories.
4. `apps/zircon/src/views/git_sidebar.zig` — no hunk-level staging or conflict editor (file/whole-tree staging only).

## Capability limitations

- No direct PNG viewing; OCR and pixel sampling only.
- No tests run; native test counts taken from inspection/user statements.
- Screenshots do not prove keyboard behavior, Git semantics, responsiveness, IME, or VoiceOver.
- Markdown incremental streaming claims are not adopted.
- This 8/10 rates UI quality and existing workflows only; it is not full Zed feature parity.