# Zed evidence and Zircon priorities

Retrieved **2026-11-06** through GitHub's REST/GraphQL APIs and official documentation source. Zed `main` resolved to [`4a6121bb0f10c6e8037b741b7dc0a4cd639ae289`](https://github.com/zed-industries/zed/tree/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289), matching [zed-ui-reference.md](zed-ui-reference.md). Zircon observations describe the working tree on top of `65568fc7a600c429da519c244802d3e88ae0f5e3`, including concurrent uncommitted work. This is source research, not a runtime verification or benchmark. The source observations below were captured before the implementation pass in this thread.

## Implementation update from this pass

The editor now corrects Foundation's `NSNotFound` sentinel, shares menu rows across palette and popups, offers four directional two-pane layouts, permits 120-pixel sidebars, loads bounded workspace shortcut overrides, follows system appearance, and shows current-line blame with expandable commit-message previews and Copy SHA. See the [editor guide](../editor-guide.md) for settings and controls. The gap descriptions below preserve the research snapshot; they are not a claim that these delivered items remain absent.

Remaining work includes arbitrary pane trees, context-aware and multi-stroke keymaps, configurable paired extension themes, fuzzy picker ranking, remote commit permalinks, full-message scrolling, and broader search options. This pass does not establish performance superiority or full Zed parity.

## Recommended order

This order is an engineering recommendation based on daily editing dependencies and implementation gaps. GitHub reactions do not establish Zircon users' priorities.

| Order | Deliverable and implementation gap | Acceptance condition |
| --- | --- | --- |
| P0, current parent work | Finish UI and text-input correctness. Keep focus, selection, clipboard, IME, hit testing and readable text ahead of additional editor features. Public reports about keyboard layouts and text clarity support investigating these workflows, without proving Zircon has the same defects. | Exercise physical shortcuts, Unicode insertion/composition, selection and clipboard in both editor panes and overlay/settings fields. Opening and dismissing a picker restores useful focus. |
| P1 | Make commands consistent across palette, buttons and shortcuts. Zircon has a shared command enum, but palette membership, shortcut labels and bindings remain separate lists. Resolve displayed shortcuts from effective bindings and offer user overrides with explicit unbinding and focus contexts. | Every applicable user action is searchable; palette and button execution agree. Rebinding an action updates its displayed shortcut. Text-field editing shortcuts target the focused field. |
| P1 | Add explicit Split right and Split down actions, then left/up and keyboard pane focus/close. Current Split editor toggles one secondary pane in a fixed row. | Both orientations work through palette and bindings; buffers share document edits while retaining independent selection/scroll. Closing a pane keeps the remaining document and focus. Decide separately whether arbitrary nesting is needed. |
| P1 | Add System / Light / Dark appearance mode while retaining separate light/dark theme choices. Both fixed palettes already exist. System observation and native-window appearance are missing. | Persist mode; react to a live OS appearance change; update editor, settings, inputs, popups and native window chrome together. Explicit Light/Dark ignores OS changes. |
| P2 | Improve the existing blame card. First expose it as a keyboard command and show the timestamp already available; then add copy SHA, full commit message and a real commit link when resolvable. | Gutter and keyboard open the same revision-correct details. Uncommitted lines have an explicit state. Dismissal, narrow windows and scrolling preserve source readability. |

## Verified Zed behavior and local gaps

### Command palette consistency

Zed's [command-palette documentation][palette-doc] calls it the main way to access actions. Its [getting-started guide][start-doc] documents `Cmd+Shift+P` on macOS and `Ctrl+Shift+P` on Linux/Windows. The [implementation][palette-src] obtains `window.available_actions`, applies visibility filtering, fuzzy matches command names, and renders `KeyBinding::for_action_in` against the previous focus handle. This supports context-aware action discovery and effective shortcut display. It does not prove every Zed control appears in the palette.

Zircon's [commands.zig](../../apps/zircon/src/commands.zig) lists palette entries and `bindings` separately, with literal shortcut strings. For example, Open folder or Git repository advertises `Shift+Cmd+O`, but that chord is absent from the workspace binding array. The palette opener itself and Git stage/unstage/commit actions are absent from the palette list. Undo/redo can also be handled by the editor, so absence from the workspace binding array alone does not establish a broken shortcut. [view.zig](../../apps/zircon/src/view.zig) uses ASCII case-insensitive substring matching, not fuzzy ranking. [actions.zig](../../apps/zircon/src/actions.zig) dispatches palette entries through the shared command handler. Extend this existing path and audit action coverage before adding another command system.

### Directional splits and configurable bindings

Zed's [default macOS keymap][macos-keymap] binds `Cmd+K` followed by an arrow to `pane::SplitUp`, `SplitDown`, `SplitLeft` or `SplitRight` in the `Pane` context. `Cmd+\` maps to SplitRight in the full-editor context. These are explicit directions; "horizontal split" alone is ambiguous. The [key-binding documentation][keys-doc] describes `keymap.json`, action arguments, contexts, multi-stroke sequences, user overrides and `null` bindings. It also documents a graphical keymap editor. Those are Zed capabilities, not requirements to reproduce the full editor immediately.

Zircon's [shell.zig](../../apps/zircon/src/shell.zig) stores one optional `secondary` pane. [actions.zig](../../apps/zircon/src/actions.zig) creates or removes it, and [view.zig](../../apps/zircon/src/view.zig) always arranges panes in a row with a draggable divider. No split direction, user keymap loader or binding settings appear in the inspected workspace code. Add direction to the pane model and expose stable actions before expanding the settings UI.

### Inline blame detail cards

Zed's [Git documentation][git-doc] describes current-line blame and its visibility/delay settings. Its [editor code][blame-editor] implements a separate detail popover, including keyboard `BlameHover`; the default macOS binding is `Cmd+K Cmd+B`. The [blame UI renderer][blame-ui] shows author/email, commit message, timestamp and copy SHA, with commit navigation and conditional permalink support. Do not equate the brief current-line annotation with the expanded card.

Zircon already implements real blame. A gutter click in [actions.zig](../../apps/zircon/src/actions.zig) calls the [Git service](../../apps/zircon/src/services/git.zig), which supplies unsaved document contents to [Repository.blame](../../packages/zircon_git/src/root.zig). The [canvas](../../packages/zircon_editor/src/canvas.zig) draws an 88-pixel block with author, short SHA and summary. [annotations.zig](../../packages/zircon_editor/src/annotations.zig) reserves vertical space and stores the timestamp, which the card currently does not display. Email and uncommitted status exist in [the Git result model](../../packages/zircon_git/src/history.zig) but are not retained in the editor annotation. Full message retrieval, interactive card actions and a palette command need additional plumbing.

### System, light and dark themes

Zed's [theme documentation][themes-doc] explicitly supports `theme.mode` values `system`, `light` and `dark`, with separate light/dark theme names. Theme selection previews changes and saves on confirmation.

Zircon's [settings store](../../apps/zircon/src/settings/store.zig) persists one theme ID. [shell.zig](../../apps/zircon/src/shell.zig) resolves built-in light/dark colors and extension themes; [settings/view.zig](../../apps/zircon/src/settings/view.zig) offers One Light and One Dark plus installed contributions. No system-mode setting or OS appearance observer was found. [The macOS window backend](../../packages/zircon_ui/src/platform/macos/window.zig) explicitly sets `NSAppearanceNameDarkAqua`, so light content alone does not provide matching native chrome.

## What public users have actually said

All counts below are GitHub issue **`+1` reactions**, retrieved 2026-11-06, not total reactions, unique users across issues, or survey votes. States are retrieval-time states. Closed issues record historical requests or reports; closure alone does not establish a current fix. The examples were selected through repository-wide reaction sorting and topic-specific title searches, so they are a biased sample of public participants, not representative demand.

| Primary report | Observed signal | Practical implication |
| --- | --- | --- |
| [#5844, Unable to remove specific keybindings](https://github.com/zed-industries/zed/issues/5844) | 25, closed. Author reports default Option bindings preventing Czech-layout brace entry. | Rebinding/unbinding can be basic text-input functionality. |
| [#5326, Auto switching light/dark theme](https://github.com/zed-industries/zed/issues/5326) | 63, closed. Requests following system appearance. | A concrete precedent for System mode. |
| [#4793, Git in-line blame indicators](https://github.com/zed-industries/zed/issues/4793) and [#12133, Blame in status bar](https://github.com/zed-industries/zed/issues/12133) | 125 and 55, both closed. The second author finds gutter blame distracting. | Offer control over blame visibility; these do not measure demand for a particular detail-card design. |
| [#15722, Other buffer when splitting](https://github.com/zed-industries/zed/issues/15722) | 45, open. Requests an alternative to duplicating the current buffer. | Split behavior preferences differ. This is not evidence that directional splitting is missing in Zed. |
| [#8279, Telescope-style search box](https://github.com/zed-industries/zed/issues/8279) | 889, closed. Requests search as you type, preview and keyboard browsing. | Prioritize a reliable search/picker workflow after input fixes. |
| [#7992, Font rendering on LoDPI displays](https://github.com/zed-industries/zed/issues/7992) | 514, closed. Reports blurry text with screenshots. | Verify text on ordinary-density displays as well as Retina. |
| [#4355, Smooth scrolling](https://github.com/zed-industries/zed/issues/4355) and [#5242, Test runner integration](https://github.com/zed-industries/zed/issues/5242) | 899 and 894, both open. | Broader workflow signals for later planning, not reasons to expand the current UI/input pass. |

[Discussion #66354](https://github.com/zed-industries/zed/discussions/66354), retrieved the same day with **1 upvote**, proposes a top-level Git menu for discoverability despite existing palette actions. This is one participant's migration experience. It supports testing both mouse and keyboard entry points, not claiming universal menu preference. [Issue #8107](https://github.com/zed-industries/zed/issues/8107), 20 `+1`, closed, requests recency rather than usage ordering in the palette; even ranking preferences differ.

## Claims in the comparison that need correction or evidence

The [comparison HTML](zed_vs_zircon_comparison.html) is unchanged. It has no benchmark procedure or pinned citations for most quantitative claims.

- **Bidi parity is contradicted by Zed's own tracker.** The comparison says Zed handles bidi. [Open tracking issue #31102](https://github.com/zed-industries/zed/issues/31102) states that RTL input/rendering is unsupported. Distinguish shaping glyphs from correct bidirectional editing.
- **The stale-window alias mechanism is unsupported.** Handles use generation 1, but [App.openWindow](../../packages/zircon_ui/src/app/app.zig) appends a new slot and lookup rejects closed/null entries. The claimed close-and-reuse alias requires slot reuse that this path does not perform.
- **Memory superiority is unmeasured.** [#24724](https://github.com/zed-industries/zed/issues/24724) reports 21+ GB on a TypeScript monorepo; [#7939](https://github.com/zed-industries/zed/issues/7939) initially reports 220 MB growing to 350 MB. Both are closed. Neither proves "unbounded cache growth" as a general cause or Zircon's claimed 10-30 MB idle floor. [shaping.zig](../../packages/zircon_ui/src/text/shaping.zig) explicitly calls its 4 MiB cache accounting an estimate, not an OS allocation counter. Active documents, native objects, jobs and GPU resources prevent treating selected cache budgets as a process-wide hard bound.
- **Hot-path observations need measurements.** [metal.zig](../../packages/zircon_ui/src/graphics/backends/metal.zig) does extract glyph IDs/positions inside a glyph loop, and the editor canvas draws colored substrings separately. That supports investigating bulk extraction and line shaping. It does not establish "4k-6k C calls/frame", cache thrashing or a measured speedup. The frame discard path still uses `retain_capacity` in [tree.zig](../../packages/zircon_ui/src/ui/tree.zig), which also contradicts the HTML's blanket hard-ceiling claim.
- **The settings failure is not freshly reproduced.** The test is concurrently modified, and [the UI reference](zed-ui-reference.md) records a different, previously fixed native `BorrowConflict`. Run the current checks before prescribing changed assertions; source inspection cannot certify `zig build check` fails now.
- **Packaging judgments are presented as defects without demonstrated impact.** Shipping embedded fonts or source SVGs can be intentional. `git ls-files` returned neither named baseline executable, so "committed or stored locally" does not establish committed binaries. Cache disk usage, file/crate/LSP counts, 120 FPS and per-window memory figures need dated commands or measurements. A per-window renderer exists, but that alone does not prove a distinct physical GPU device per window. These are not established user priorities.

## Primary implementation references

All references below were retrieved 2026-11-06 and pinned to the inspected Zed revision. Official published routes include [command palette](https://zed.dev/docs/command-palette), [key bindings](https://zed.dev/docs/key-bindings), [themes](https://zed.dev/docs/themes) and [Git](https://zed.dev/docs/git); the exact inspected documentation source is linked below.

[palette-doc]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/docs/src/command-palette.md
[start-doc]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/docs/src/getting-started.md
[palette-src]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/command_palette/src/command_palette.rs
[keys-doc]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/docs/src/key-bindings.md
[macos-keymap]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/assets/keymaps/default-macos.json
[git-doc]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/docs/src/git.md
[blame-editor]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/git.rs
[blame-ui]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/git_ui/src/blame_ui.rs
[themes-doc]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/docs/src/themes.md
