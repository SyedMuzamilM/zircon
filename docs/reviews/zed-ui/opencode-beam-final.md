# Zircon native editor final review (opencode/beam)

## Inspection limits

- This model cannot inspect PNG images. The retained PNGs were not visually scored, and no subjective color/hierarchy score is invented.
- Dimensions were checked with `ImageMagick identify` (editor frames 1240×820, settings frames 1000×700); no color sampling, OCR scoring, or desktop control was used.
- Evidence used: current source under `apps/zircon/src`, `packages/zircon_editor/src`, `packages/zircon_ui/src`, portable/native journey tests, and `docs/reviews/zed-ui/{rubric,inspection,opencode-beam-baseline}.md`.
- No app code, commits, native suite execution, or delegation was performed. Parent suites are running separately.

## Scores (0..2 per rubric category)

| Category | Score |
|---|---:|
| 1. Visual hierarchy and geometry | unverified |
| 2. Color and typography | unverified |
| 3. Menus and controls | 2/2 |
| 4. Editor interactions | 2/2 |
| 5. Existing project workflows | 2/2 |

Sum of scored categories: **6/6** (categories 1 and 2 remain unverified, so no 10/10 claim is made).

## Evidence for scored categories

### 3. Menus and controls (2/2)

- Compact command/file picker: `apps/zircon/src/view.zig` uses a fixed 38px query field, 30px rows, `resultStyle` radius `metrics.control_radius`, and a 24px hint footer (`↑ ↓ to navigate`, `↵ Confirm`, `esc Close`).
- Undimmed palette: picker shade is `a = 0` (`view.zig`, overlay), while non-picker overlays remain dimmed at `0.2`.
- Dismissal: `closePicker` (`settings/view.zig`) and overlay pointer handling close on outside `pointer_down`; covered by `workspace_polish_tests.zig` "compact command palette preserves query height, source visibility and outside dismissal".
- Anchors: completion uses the committed caret (`view.zig`, `frames.committed.text_input.caret`) and `popoverBounds`; settings pickers use `picker_anchor` plus `popoverBounds`.
- Selected rows use `c.selected`, while text selection uses `c.selection` in stock themes (`components.zig` `inputAppearance`; `theme.zig` dark/light both define distinct `selection` vs `selected`).
- Shared radii: `components.zig` metrics now resolve to `ui.controls.metrics.control_radius` (4) and `popover_radius` (6); inputs, buttons, menu rows, result rows, floating panels, blame cards, and extension cards use those tokens. Switch remains a deliberately pill-derived 9/6 radius.
- Installed font picker: `settings/view.zig` `choiceList` appends `surface.fontFamilies`; native journey verifies more than 10 families.

### 4. Editor interactions (2/2)

- Ordinary/native input, composition, macOS deletion, and split focus are exercised by portable/native journeys.
- Continuous multiline selection is implemented and asserted by `packages/zircon_editor/tests/all.zig` "multiline selections fill continuous rows..." (3 contiguous bands, empty middle line remains visible).
- Vim modes/operators are covered by `native_journey.zig` and experience tests.
- Caret-anchored completion is covered by `experience_tests.zig` (completion bounds match committed caret; Up/Down changes selection; Enter applies).

### 5. Existing project workflows (2/2)

- Tree ancestor reveal is implemented in `actions.zig` `revealTreePath` and covered by `workspace_polish_tests.zig` "opened nested source reveals only its project ancestors".
- UTF-8-safe intraline diff is implemented in `packages/zircon_editor/src/annotations.zig` `changedColumns`, with boundary repair on UTF-8 continuation bytes; exercised by editor tests.
- Git diff summary counts are responsive at 560px (counts) and 660px (labels) instead of a hard 950px cutoff; paired addition/deletion runs produce intraline highlights in `views/git_diff.zig`.
- Blame, hunks, staging, search, and Markdown flows are represented by existing journeys.

## Concrete bugs / residual risks

1. Extension themes still alias text selection to row selection: `apps/zircon/src/settings/view.zig:526` sets `c.selection = c.selected`. Stock themes are distinct, but extension-supplied themes conflate them.
2. Settings `Switch` paints hardcoded radii 9 and 6 (`settings/view.zig:517-518`) rather than the shared tokens; baseline documents this as pill-derived, but it is not token-driven.
3. `open_project.zig:28` hardcodes panel radius 6 instead of `ui.controls.metrics.popover_radius`; `markdown.zig:295,400` and `code_line.zig:40` hardcode 3/5/2. These are cosmetic, not token-driven.
4. `chrome.zig` tab capacity uses `tool_count` as `f32` and the fragile expression `width < 520 + (tool_count - 1) * 100` (`chrome.zig`, tabs function). It is gated by `utility`, but remains hard to audit.
5. IME/full foreground input-method and VoiceOver acceptance remain unverified; native tests use hidden AppKit windows and window-bound events.

## Full Zed feature gaps (separate from this UI score)

Arbitrary pane trees, native application menu/terminal/debugger, collaboration, full LSP navigation/refactoring, complete Vim, soft wrapping/grapheme motion, and asynchronous Markdown are not supplied by this UI pass and must not be represented as parity.

## Unverified visual categories

Categories 1 and 2 are intentionally left unverified because PNG inspection is unavailable to this model. No visual hierarchy, geometry, color, or typography score is claimed from code alone.
