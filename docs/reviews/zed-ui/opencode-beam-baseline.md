# Zircon native editor baseline review (opencode/beam)

## Inspection limits

- This model cannot inspect PNG images. All visual observations from the baseline/reference PNGs are **unverified**; no visual score is invented.
- Evidence used: `docs/reviews/zed-ui/rubric.md`, source under `apps/zircon/src/views`, `apps/zircon/src/settings/view.zig`, and portable/native journey tests (`apps/zircon/tests/*`). No desktop control, native test runs, app-code changes, commits, or delegation were performed.

## Scores (0..2 per rubric category)

1. Visual hierarchy and geometry: **unverified** (PNG inspection unavailable)
2. Color and typography: **unverified** (PNG inspection unavailable)
3. Menus and controls: **1/2**
4. Editor interactions: **2/2** (code/test evidence; continuous drag-selection and IME acceptance remain unverified)
5. Existing project workflows: **2/2**

Sum of scored categories: **5/6** (2 of 5 categories unverified).

## Concrete defects

1. **Text selection color is not distinct from row focus/selection.** `apps/zircon/src/views/components.zig` sets `selection = c.selected` in `inputAppearance`, while `menuRow`, `iconButtonStyle`, and settings rows also use `c.selected` as their selected-row background. Extension themes make this worse by setting `hover = selected` (`apps/zircon/src/settings/view.zig`). This conflates selected text, focused rows, and hover.
2. **Hover/selection/border colors are nearly identical in the dark palette.** `apps/zircon/src/theme.zig`: `hover = 0x363c46`, `selected = 0x364357`, `border_subtle = 0x363c46`. Low contrast between hover and selection and between hover and borders.
3. **Inconsistent corner radii.** `metrics.control_radius = 3`, `popover_radius = 5`, settings `Switch` paints radius `9`, and some buttons use radius `4` (`resultStyle`). "Shared radii" are not actually shared.
4. **Narrow-window utility-tab condition may underflow conceptually.** `chrome.zig` tabs capacity uses `width < 520 + (tool_count - 1) * 100` with `tool_count` as `f32`; when no tool tabs are open this threshold becomes 420 and the branch is gated by `utility`, but the expression is fragile and hard to audit.
5. **Git diff change counts disappear below 950px viewport width** (`git_diff.zig`: `if (b.viewport().width > 950)`), so smaller/narrow split layouts lose summary affordance abruptly.
6. **No native application menu** (documented limit). Menus are in-app popovers only; keyboard hints exist but OS-level menu integration is absent.
7. **Settings switch thumb uses `c.text`/`c.muted` on tracks `primary`/`line`**, which can reduce on/off contrast in light themes (visual unverified).
8. **Visual hierarchy, clipping at narrow sizes, and measured text alignment cannot be verified** without PNG inspection (rubric category 1).

## Prioritized fixes

P1. Separate selection colors: introduce distinct `text_selection` (and keep `selected` for rows) in `Palette` and `inputAppearance`; stop setting `hover = selected` in extension themes; differentiate hover from selection/border in base themes.

P2. Normalize radii: define one shared `control_radius`, `popover_radius`, and `switch_radius` usage; apply consistently across buttons, popovers, result rows, and settings switch.

P3. Make Git diff summary counts responsive by viewport/panel width thresholds rather than a hard 950px cutoff; verify in narrow split layouts.

P4. Add/verify continuous multiline drag selection and IME acceptance tests (native) to close the unverified editor-interaction gap.

P5. Add native macOS menu integration or document its absence as an explicit non-goal; keep command palette as the in-app fallback.

P6. Provide image-capable review pass to score visual hierarchy/color categories; current run cannot assign those scores.
