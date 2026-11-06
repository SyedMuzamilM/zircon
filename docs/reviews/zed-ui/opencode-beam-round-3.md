# OpenCode Beam native UI review, round 3

Reviewed application source `2faf2bb` (candidate commit `04269cc`) against installed Zed Preview 1.28.0 captures in `docs/reviews/zed-ui/evidence/`. Rubric: `docs/reviews/zed-ui/rubric.md`; capture/layout limits: `docs/reviews/zed-ui/inspection.md`. Extension compatibility limits: `docs/zed-extensions.md`.

## Scores

| Category | Score | Basis |
| --- | ---: | --- |
| 1. Visual hierarchy and geometry | 1/2 | Close chrome/tab/tree/gutter/divider geometry and narrow-window containment; breadcrumbs remain path segments rather than semantic symbols, and the gutter keeps a 52-pixel minimum with no fold controls. |
| 2. Color and typography | 2/2 | Dedicated dark/light text-selection colors, distinct row focus, separate active/inactive selection, stronger gutter/folder contrast, theme-derived Markdown code colors, and focused-pane-only active line/number. |
| 3. Menus and controls | 2/2 | Command palette, searchable font/theme pickers, caret-anchored completion, outside dismissal, keyboard hints, shared radii, and wider narrow-window palette are implemented and captured. |
| 4. Editor interactions | 2/2 | Native/portable regressions and observed journeys cover ordinary UTF-8 input, composition transactions, macOS deletion, continuous selection, Vim modes/operators, wrapping, and split focus. |
| 5. Existing project workflows | 2/2 | Git stage/review/hunks, search, Markdown preview/code wrapping, settings, and real ZLS/Pyright/catalog journeys are implemented and asserted. |
| **Total** | **9/10** | Quality of the rubric's implemented workflows only. This is not full Zed feature parity. |

## Concrete findings

### Visual hierarchy and geometry (1/2)

- Positive: thin dividers retain a 5-pixel drag target; adjacent tabs share one border; folder labels are neutral; gutter line numbers have stronger contrast; narrow 700 × 650 captures show canvas containment above the status bar; the palette can use up to 560 pixels with a 24-pixel inset so long command labels fit at 700 pixels.
- Defect, medium: breadcrumbs are clickable file-path segments, not semantic symbol breadcrumbs. This is documented as a non-semantic path control, so the header cannot provide Zed-style symbol navigation.
- Defect, low: `packages/zircon_editor/src/canvas.zig` `gutterWidth()` reserves `@max(52, ...)` pixels and there are no fold controls; dense files therefore carry more horizontal gutter space than Zed's compact gutter.
- Architecture difference, not scored as a missing native control: Zed's captures show a separate right Git dock, while Zircon switches its left rail to Git. This is an intentional pane-architecture difference and must not be read as missing traffic lights or native window chrome; native tests verify AppKit traffic-light objects separately.

### Color and typography (2/2)

- Distinct selection colors are present in both themes: dark selection `0x3d5275` versus active line `0x2f343e`; light selection `0xc6d2f5` versus active line `0xeef1f5`.
- Inactive text selection retains a separate theme color (`inactive_selection`), and focused split canvases exclusively paint the active line and bright line number; a native click regression checks that the highlight moves between panes.
- Markdown fenced code now uses editor theme token colors, preserves indentation, and wraps long tokens instead of clipping; a regression asserts color, indentation, and preview containment in the light case.
- Limit: imported theme styles and color tokens remain partial; Zircon maps Tree-sitter highlights into seven token categories and has no semantic tokens. This is a compatibility limit, not a failure of the basic light/dark selection and surface distinctions.

### Menus and controls (2/2)

- The command palette uses a single search header, compact rows, undimmed source, navigation/confirmation hints, a border, a restrained shadow, and a fixed search height that cannot collapse under results.
- Searchable font and theme pickers are present in the settings captures; theme choices include One Dark and One Light.
- Completion is anchored to the committed caret and supports Up/Down selection; palette clicks outside dismiss without editing source.
- Shared corner tokens are used for stock text fields, settings controls, popup cards, and blame; pill switches retain a radius derived from their shape.
- The narrow palette evidence shows long labels remain visible at 700 × 650.

### Editor interactions (2/2)

- Native/portable coverage includes ordinary UTF-8 input, stale native ranges, composition transactions, macOS deletion, continuous multiline selection, Vim Normal/Insert/Visual modes and operators, split resizing/focus, and font discovery/resolution.
- Word wrapping is cached by visual row, uses UTF-8 boundaries, reuses unchanged maps, reshapes changed lines, and supports vertical/pointer navigation and Git/blame geometry.
- Split focus painting is verified by a native click regression that moves the active-line highlight and bright line number to the other pane.
- Unverified behavior: native tests drive hidden AppKit windows with synthetic/window-bound events. They do not establish full foreground input-method acceptance or VoiceOver behavior. No frame-rate or latency measurement exists.

### Existing project workflows (2/2)

- Git workflows include changed-file review, stage/unstage/all, commit-message gating, hunk display, combined diff navigation, blame, and stash/branch/network operations in the inspected implementation and tests.
- Project search and settings are captured in both themes; settings receives the resolved parent appearance before first field render, avoiding dark search in a light settings window.
- Markdown preview supports source navigation, images, and wrapped fenced code with indentation and theme token colors.
- The native package journey exercises real ZLS and Pyright initialization/completion, automatic dot completion, acceptance/undo, theme/icon application, wrapping, and official catalog installation.

## Evidence and method limits

- I could not view PNG bytes directly as images in this model. I inspected retained captures through OCR (`tesseract`), ImageMagick dimensions/color quantization, and the documented manifest; visual color/layout conclusions are therefore secondary to the documented capture method and source/tests.
- Screenshots cannot establish performance, IME, VoiceOver, Git semantics, keyboard semantics, responsiveness, or frame rate.
- Native tests use hidden windows and synthetic events; they are behavior evidence, not manual foreground typing.
- Validation results reported by the parent (build/test-settings-native, Linux cross-build, ReleaseFast, icon/format checks, and `verify-zed-extensions`) are accepted as stated; I did not rerun them.
- No latency benchmark exists. Grammar and LSP work run off the UI thread but reparse/re-run rather than maintaining incremental parse trees; wrapping copies its visual-row index after edits.

## Full Zed feature-parity gaps (separate from this score)

These do not reduce the rubric score above, but they are not implemented or certified: terminal/debugger; arbitrary pane trees; LSP hover, definition/reference navigation, rename, formatting, and code actions; collaboration; complete Vim; semantic tokens; incremental Tree-sitter sessions; background/incremental Markdown rendering; full grapheme/bidi handling; AI agents, context servers, debug adapters/locators, slash commands, snippets; unsupported WASM host imports; and universal extension compatibility. Catalog visibility is not certification of every package. See `docs/zed-extensions.md` for exact adapter and performance limits.