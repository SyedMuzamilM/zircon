# Zircon native editor UI review — Crouton final

Reviewer: opencode-crouton (independent). Scope: CURRENT Zircon in `/Users/syedmuzamilm/work/expirements/zigpui` vs Zed Preview 1.28.0, using `rubric.md` + `inspection.md`, evidence PNGs in `docs/reviews/zed-ui/evidence/` (manifest hashes verified OK), source + tests. No desktop driven, no native tests run, no app code changed.

## Evidence method and limits

I could view the PNGs directly (`read` returned images) and sampled pixels with a stdlib PNG decoder. Scope checks: `zed-dark-editor.png` 1240×820, `zircon-dark-selection.png` 1240×820, `zircon-dark-settings.png` 1000×700; all 23 manifest hashes match. Fixture covers dark/light × editor/selection/commands/git/settings/split (split is Zircon-only; Zed diff is Zed-only). Zircon PNGs omit AppKit traffic lights by capture design; their presence is verified in `apps/zircon/tests/native_journey.zig:64-68`, not by these PNGs — not a Zircon defect per rubric.

What PNGs do NOT prove (per rubric): keyboard behavior, Git semantics, responsiveness, VoiceOver, IME foreground composition. Those are cited from tests only where stated. No completion, Markdown-preview, or project-search PNG exists in this evidence set — those flows are marked visually unverified below.

## Scores (rubric 0–2, total 10)

1. Visual hierarchy and geometry: **1**
2. Color and typography: **1**
3. Menus and controls: **1**
4. Editor interactions: **2**
5. Existing project workflows: **1**

**Total: 6 / 10**

I do not inflate. Each 1 is backed by a concrete remaining defect; 2 is given only where the rubric items are both implemented and test-pinned.

---

## 1. Visual hierarchy and geometry — 1

Verified good: titlebar (project + branch, `apps/zircon/src/views/chrome.zig:7-17` 34px), tabs with tab-history chevrons, tree, gutter, status bar at 1240×820 in both themes (`zircon-dark-editor.png`, `zircon-light-editor.png`). Thin divider paint is real: 5px drag target with 1px paint (`apps/zircon/src/view.zig:135-137`), pixel line at the sidebar boundary is a single 0x3E4450 column. Adjacent tabs share a border (`chrome.zig:37`). Narrow behavior is test-pinned: utility-tab clipping (`apps/zircon/tests/view_tests.zig:57-70`), sidebar shrink to 120px (`workspace_polish_tests.zig:72-85`), split-menu clamping (`workspace_polish_tests.zig:149-174`).

Why not 2:
- Breadcrumb is path-only (`chrome.zig:83-94` shows `src/main.zig`); Zed shows `src/main.zig › pub Session struct` in `zed-dark-editor.png`. Same for indent guides and fold chevrons (`>` at lines 15/24 in Zed PNG; absent in Zircon PNGs). Fixable: add symbol/line context to `fileHeader` and row guides.
- Split clipping: `zircon-dark-split.png` right pane hard-clips long lines (`var session: Session = .{ .name = "Editor Review" };`) at the pane edge with no scrollbar/wrap indicator, unlike Zed's visible horizontal scrollbar in `zed-light-editor.png`. The editor tracks `horizontal` scroll but the split layout gives no affordance. Fixable: horizontal scroll thumb or reveal-on-caret in split.
- Left-rail Git vs Zed right dock is an architecture difference (`inspection.md` acknowledges it); it does not alone deduct here, but it means Git geometry cannot claim visual parity.

Tree reveal claim verified: `actions.zig:90-97` `revealTreePath` + `openPath:111`, test `workspace_polish_tests.zig:220-236`.

## 2. Color and typography — 1

Measured (not eyeballed): dark selection sample (61,82,117) = `0x3D5275` (`packages/zircon_editor/src/theme.zig:11`), light (198,210,245) = `0xC6D2F5` (`theme.zig:18` light). Both are distinct from active-line (`0x2F343E` / `0xEEF1F5`) and from inactive selection (`0x33425A` / `0xE0E5F1`). Selected rows are neutral (`0x3B414D` / `0xE2E5ED`, `apps/zircon/src/theme.zig:23-26`). Far-right samples at the selected row are background, not selection — no right-edge paint, confirming the selection-geometry fix. Canvas paints full `line_height` bands with a newline cell (`packages/zircon_editor/src/canvas.zig:124-131` adds `font_size*0.6` when crossing lines); test `packages/zircon_editor/tests/all.zig:511-534` pins three continuous bands and contrast (`all.zig:679-686`).

Why not 2:
- Light syntax contrast is weak next to Zed: `zircon-light-editor.png` keywords/strings render pale vs Zed's stronger One Light tokens in `zed-light-editor.png` (e.g. `const`, `"Editor Review"`). Light tokens (`theme.zig:18`) are muted. Fixable: raise luminance gap for light code tokens.
- Custom-theme override collapses the distinction: `apps/zircon/src/settings/view.zig:526` sets `c.selection = c.selected`, so extension themes make text selection identical to row focus. Fixable: derive a distinct selection from the theme instead.
- Gutter contrast passes its own test (≥3:1) but dark inactive numbers remain dimmer than Zed’s; acceptable, not a full-parity claim.

Light-settings initialization claim verified: `settings/view.zig:56-66` applies `initial_colors` before `onSettings`, test `settings_tests.zig:270-301` asserts a light search backdrop, runner refuses dark-in-light (`tools/capture_ui_review.zig:83`), and pixel sample shows light search (250,250,250) vs dark (40,44,51).

## 3. Menus and controls — 1

Palette verified: single search header at 38px fixed height (`view.zig:171`, test `workspace_polish_tests.zig:204-219` asserts exact 38px, ≤560px width, no full-window dim `view.zig:226` alpha 0 for pickers, outside dismissal `shell.zig:308-314`). PNGs (`zircon-dark-commands.png`, `zircon-light-commands.png`) show compact 30px rows, selected row, `↑↓ to navigate / ↵ Confirm / esc Close` (`view.zig:194`), border + restrained shadow (`components.zig:98-117`). Shared radii via `control_radius`/`popover_radius` (`components.zig:8-10, 32, 84, 113-115`). Split-menu anchor clamping is test-pinned.

Why not 2:
- No PNG evidence for the workspace menu, split menu, or font/theme pickers in this set. Sources exist (`chrome.zig:126-147`, `settings/view.zig:480-506` picker, `choiceList:427-455` with `matches()` filtering `view.zig:294-300`), and pickers are tested (`settings_tests.zig:195-244`), but visually unverified here.
- Command catalog is far smaller than Zed’s (`zed-dark-commands.png` scrolls hundreds of `agent:` commands; Zircon lists ~11 core commands in the PNG). That is a feature gap more than a control-geometry defect, but the rubric asks for searchable pickers and hints — Zircon meets the mechanics, not the breadth. Docked one point accordingly.

Dismissal claim verified only as tests (`workspace_polish:216-218`, `view_tests:83-105` Escape restores focus). No interaction was performed in this review.

## 4. Editor interactions — 2

Test-pinned (I did not run suites; parent is running them):
- Native input: hidden `NSWindow` `keyEventWithType` + `insertText:` with UTF-8/emoji refresh (`native_journey.zig:18-28, 155-194`), find/replace/save/close/dirty-protection journey (`native_journey.zig:38-152`), macOS Cmd-Delete on `0x7F` (`native_journey.zig:296-300`).
- Continuous selection: canvas `canvas.zig:124-131` + `all.zig:511-534`.
- Vim modes: Normal/Insert/Visual + `d w`, `u`, `i`, `v l`, `A` via native keys (`native_journey.zig:229-313`), slash-search returns to Normal (`workspace_polish:176-202`), Normal suppresses native insertion (`all.zig:511-548`).
- Split focus/resize: directional splits + drag (`workspace_polish:48-71`), ratio math (`view_tests:138-155`).

Completion placement/keyboard claim verified from source + tests (not from PNG — no completion capture exists): anchor is the committed caret (`view.zig:44-49` reads `text_input.caret`), bounds within 1px of caret in `experience_tests.zig:308-323`, Up/Down cycle (`actions.zig:709-718`). This is the one category earning 2 for the rubric items as written; full Vim/IME/VoiceOver/soft-wrap/graph­eme limits belong to the separate parity inventory below.

## 5. Existing project workflows — 1

Inspected in PNG + tested (not run here):
- Git: Changes(2)/History tabs, Tracked tree, per-file `M` + checkboxes, `View diff/Stage all`, `main` + `Publish`, commit field, combined diff `All uncommitted changes · HEAD → worktree` with `+3 −3` in `zircon-dark-git.png` / `zircon-light-git.png`. Intraline claim verified: paired balanced runs (`views/git_diff.zig:156-174`) + UTF-8-safe `changedColumns` (`packages/zircon_editor/src/annotations.zig:94-108`) + strong tint (`git_diff.zig:143-149`); PNG digits (`0→1`, `1→2`, `0x354d70→0x3c557a`) are visibly highlighted. Width-dependent summaries (`git_diff.zig:55`) verified in code. Journey tests cover stage/unstage/commit/gutters/blame (`experience_tests.zig:369-…`), stash/branch/network (`…:733-…`), inline hunk expansion (`…:687-…`).
- Search: project-search field + results (`services/search.zig`, `views/search.zig`), find/replace overlays (`view.zig:206-214`, `actions.zig:613-641`), Vim `/` search. Test `experience_tests.zig:560-…` covers unsaved-buffer search + real selection. No search PNG in evidence — visually unverified.
- Markdown: native preview (`views/markdown.zig`, `packages/zircon_markdown`), preview toggle in `chrome.zig:92`, actions `markdown_preview` (`actions.zig:324-334`). No Markdown PNG in evidence — visually unverified; remote images are documented as unavailable.
- Settings: search, category rail, theme/font pickers, JSON edit, persistence (`settings_tests.zig:87-150, 151-193`), init fix above.

Why not 2:
- Concrete defect: “Commit staged” is always styled primary/enabled (`views/git_sidebar.zig:55` `buttonStyle(c,true)`) even when nothing is staged — the evidence PNGs show unchecked `M` rows with a blue commit button while Zed’s “Commit Tracked” is muted. Fixable: disable when no staged entries.
- Missing-but-in-rubric Git: no hunk staging, no conflict editor, no discard/restore menus (status notes). Within-rubric gaps must deduct.
- Settings breadth (4 categories in `settings/view.zig:9` vs Zed’s 15 in `zed-dark-settings.png`) and search/Markdown visual unverified prevent a higher score.

---

## Concrete fixable defects (source locations)

1. `apps/zircon/src/views/git_sidebar.zig:55` — disable “Commit staged” when no staged changes (compare Zed `zed-dark-git.png` muted state).
2. `apps/zircon/src/settings/view.zig:526` — do not set `selection = selected` for extension themes; derive a distinct selection.
3. `apps/zircon/src/views/chrome.zig:83-94` — `fileHeader` shows bare path only; add symbol/line breadcrumb to match `zed-dark-editor.png`.
4. Split horizontal affordance — `zircon-dark-split.png` clips with no scrollbar; add thumb/wrap/reveal (editor `horizontal` state exists in `packages/zircon_editor/src/canvas.zig`).
5. Light code-token contrast — `packages/zircon_editor/src/theme.zig:18`; raise contrast vs `zed-light-editor.png`.
6. Palette breadth — `apps/zircon/src/commands.zig` catalog is small; search itself works (`view.zig:294-310`).

## Verified iterated claims (not taken on trust)

- Selection colors/geometry: verified (pixel + canvas + `all.zig:511` + `679` tests).
- Compact palette: verified (38px test + PNG + `view.zig:226` no-dim).
- Shared shapes/anchors: verified (`components.zig` radii, `popoverBounds:89-96`, split-anchor test).
- Thin dividers: verified (5px hit / 1px paint, pixel column).
- Light settings init: verified (`view.zig:56-66` + `settings_tests:270` + runner guard + pixels).
- Completion placement/keys: verified from tests/code; no PNG — visually unverified.
- Tree reveal: verified (`actions:90-97` + test). Intraline Git: verified (`git_diff:143-174` + `annotations:94-108` + PNG highlight).

## Full Zed parity (separate inventory, not scored here)

Arbitrary pane trees, native menu/terminal/debugger, collaboration, LSP navigation/refactoring beyond completion/diagnostics, complete Vim, soft wrapping/grapheme motion, async/remote Markdown, and Zed’s broader command/settings catalog remain absent. Nothing here should be reported as full Zed feature parity. Screenshots alone establish no frame-rate, responsiveness, or VoiceOver result.
