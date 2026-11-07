# Zed, GPUI, Zircon, and Zircon UI

Compared 2026-11-07. This is an architecture and product comparison of Zed plus GPUI against the current Zircon tree. It sits beside the November 6 [feature audit](zircon-vs-zed-audit-2026-11-06.md) and the earlier [GPUI/NanoUI source study](gpui-and-nanoui.md). It is source inspection plus public documentation and X discussion. It is not a runtime benchmark against an installed Zed binary.

Follow-up review: [recommended work and acceptance criteria](zed-gpui-actions-2026-11-07.md), backed by [pinned upstream source research](zed-gpui-follow-up-upstream-2026-11-07.md). The review corrects the list/popover limitation below, clarifies existing incremental wrap reuse, and treats the social CPU figures as unverified.

Zed is a shipping IDE. Zircon is a working macOS coding editor with a real GPUI-shaped UI framework. Zircon is smaller, more explicit, and more testable. It is also years behind as a daily IDE.

## Evidence and limits

Local evidence is the working tree on 2026-11-07: `packages/zircon_ui`, `packages/zircon_*`, `apps/zircon`, [status](../status.md), [zircon-ui API](../zircon-ui.md), [editor roadmap](../editor-roadmap.md), [editor checklist](../editor-todo.md), and the [lifecycle baseline](../benchmarks/editor-2026-11-07-lifecycle-current-git/README.md). Visual notes use the [installed-app comparison](../reviews/zed-ui/inspection.md) against Zed Preview 1.28.

Upstream evidence is Zed `main` and official docs as of 2026-11-07, including [GPUI README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md), [contexts](https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/contexts.md), [key dispatch](https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/key_dispatch.md), [accessibility](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/_accessibility.rs), [scene](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/scene.rs), [gpui.rs](https://gpui.rs/), and Zed 1.26–1.27 release notes. The November 6 [capability survey](zed-current-capabilities-2026-11-06.md) pinned Zed `e231594`. GPUI architecture in that pin still matches current `main`.

GPUI and the platform crates are Apache-2.0. Zed's editor, language, text, and `ui` crates are GPL-3.0-or-later. Zircon independently reimplemented the architecture. It does not import GPUI or Zed editor source.

Approximate size:

| Tree | Scale |
| --- | --- |
| `zircon_ui` Zig sources | about 6,100 lines |
| Zircon product Zig (`packages/` + `apps/zircon`, excluding tests) | about 24,000 lines |
| Zircon tests | about 10,400 lines |
| GPUI (unofficial republish of Zed's crate) | about 79k SLoC |
| Zed workspace | 100+ crates, over a million lines of product code |

No speed, memory, or executable-size advantage over Zed is claimed. The numbers below for Zircon are its own baseline, timed to native frame submission.

## What each thing is

Zed is a GPU-native IDE. GPUI is the hybrid UI runtime under it: persistent `Entity<T>` state, a fresh element tree every frame, Taffy layout, a GPU scene of instanced primitives, and native backends. Metal on macOS, Direct3D 11 on Windows, wgpu (Vulkan/GLES) on Linux. Nathan Sobo's 2023 pitch still describes the intent. On a 120 Hz display a frame has about 8 ms. Electron could not hit that budget, so they built a game-style renderer. Zed 1.0 shipped 2026-04-29. Weekly stables around 1.26–1.27 continue through October–November 2026 (Pyrefly, debugger hovers, DWARF/WASM debugging, agent-panel memory work).

Zircon is a Zig editor that took the same split: persistent typed entities, frame-local trees, three-phase custom leaves, a platform-neutral scene, and Metal plus CoreText plus AppKit through direct Zig `objc_msgSend`. GPUI and NanoUI are research references only. Native UI is macOS. Linux is portable compilation of tests.

The product is split into UI-independent packages (`zircon_text`, `zircon_workspace`, `zircon_git`, `zircon_language`, `zircon_search`, `zircon_markdown`, `zircon_agent`, `zircon_extensions`), `zircon_editor` for the canvas, and `apps/zircon` for the shell. That split is cleaner than Zed's GPL editor stack.

## Framework comparison

Both are the same family. Persistent entities hold application state. Each frame builds an element tree. `notify` coalesces invalidation. Custom drawing uses layout, prepaint, and paint. The GPU consumes a scene of instanced quads and atlas glyphs. Native text input uses revisioned surrounding text with UTF-16 at the OS seam. Background work posts back to the UI thread.

Neither is Dear ImGui. Neither is a classic retained widget toolkit.

### API shape

GPUI is a fluent, Tailwind-shaped DSL. `render` takes `&mut self`. Styling is method-chained. Layout is Taffy (flex, grid, wrap, block). Custom elements can lay out children. There is `uniform_list`, view caching (`entity.cached(style)`), AccessKit, actions plus key contexts, springs, and an async executor whose `AsyncApp` survives `.await`.

```rust
div()
    .flex().flex_col().gap_3()
    .bg(rgb(0x505050))
    .on_click(cx.listener(|this, _, _, cx| {
        this.count += 1;
        cx.notify();
    }))
```

Zircon UI is a typed-struct builder with comptime contracts. `render` is `*const Self`. Mutating during render is a compile error (`packages/zircon_ui/tests/compile_fail/mutable_render.zig`). Styles are a validated `Style` struct. Layout is a Zig flex subset. Custom elements are leaves. They cannot lay out children. There is no AccessKit, no Taffy, no view cache, no `uniform_list` widget, and no multi-stroke context keymap.

```zig
pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
    return b.column(.{
        .padding = ui.Insets.all(28),
        .gap = 18,
        .background = ui.Color.rgb(0x171b24),
    }, &.{
        try b.textFmt("Count: {d}", .{self.count}),
        try b.button(.{
            .label = "Increment",
            .on_click = b.onClick(increment),
        }),
    });
}
```

The counter in `examples/counter_native/main.zig` is the intended application shape.

### Ownership

This is Zircon UI's real advantage.

GPUI's `Entity<T>` is an Rc-like handle. `entity.update(cx, |this, cx| { ... })` leases `T` onto the stack. Reentrant update of the same entity is a bug. Drop is RAII.

Zircon UI is a Zig ownership model:

- `Entity(T)` is a non-owning generational handle. It never keeps the object alive.
- Ownership is application, `Scope`, or parent entity. Children destroy first. Depth is capped at 128. Generation wrap retires the slot.
- Access is callback-scoped: `app.read` / `app.update`. Results cannot contain pointers or slices. That is a compile-time snapshot rule.
- Runtime borrow flags (`readers` / `writer`) catch `BorrowConflict` on the UI thread. That is how the settings-window regression was found. AppKit's `windowDidResignKey` arrived while a workspace action still held a write borrow. Native focus notifications now drain at the next `step`.
- `Context(T)` is lease-checked. A copied context dies when the write borrow ends.
- Frame arenas, the entity store, and GPU leases have different lifetimes. A failed frame keeps the previous tree. A later GPU failure cannot un-commit the CPU frame.

### Frame pipeline

GPUI rebuilds the tree, runs Taffy, prepaints hitboxes and accessibility nodes, paints a scene, then calls platform `draw`. Optional view cache replays previous paint ranges. `Scene` holds shadows, quads, paths, underlines, monochrome/subpixel/polychrome sprites, and surfaces. `Scene::replay` can copy a previous range.

Zircon UI gives each window two arenas. Staging builds the tree, layout, scene, handlers, dependencies, animation targets, and the IME snapshot. All fallible work happens first. Commit is a nonfallible swap. Failure discards staging. Retired arenas keep at most 8 MiB. Metal independently leases in-flight buffers.

That rollback contract is stricter and clearer than GPUI's documented behavior. The cost is that every dirty window does a full rebuild, full layout, and full paint. GPUI has the same default, plus cache and `uniform_list` as escapes.

### Layout

GPUI uses Taffy: flex, grid, wrapping, block.

Zircon UI implements its own flex: row, column, stack, padding, positive margins, gap, grow/shrink with min/max freezing, align, `space_between`, overflow clip, `scroll_y`. No wrap, grid, baseline, absolute positioning, transforms, or negative margins. Editor soft wrap lives in `zircon_editor`, which is the right place for it.

For chrome this is enough. For a general toolkit it is thin.

### Rendering

GPUI's scene is a small game engine: Gaussian-ish shadows, SDF quads, path tessellation, underlines, color glyphs, video surfaces. Community work ("GPUI Fast", Jason Lee, Oct 2026) exists because rebuilding every frame still costs 40–70% CPU on dense scrolling UIs. A more retained backend dropped that to 10–25% at 120 FPS. That is an existence proof that GPUI's immediate tree is expensive at scale.

Zircon UI paints four primitives: rect with analytic radius, text, image, round-capped line. One Metal shader, four modes. 80-byte instances, max 262,144. The glyph atlas is 2048² R8 grayscale, so color emoji is monochrome. No shadows, no general paths, no SVG tessellation, no device-lost recovery. `strokeRect` is four filled rects.

For an editor this is sufficient. For chrome that wants menus, shadows, and color emoji, it is not.

### Native layer

GPUI: mature AppKit, Win32, Wayland, and X11. AccessKit on those platforms. IME, menus, dialogs, font-kit / DirectWrite / cosmic-text. iOS and experimental web crates exist. Zed ships macOS, Linux, and Windows.

Zircon UI: a runtime-allocated `NSView` subclass, `NSTextInputClient`, integrated titlebar, child windows, `NSOpenPanel`, clipboard, ImageIO, CoreText. Bindings are generated at comptime from argument tuples. There is no C header and no `.m` file. The portable module has zero native or GPU imports.

Missing: `NSMenu`, save dialogs, accessibility APIs, Linux/Windows adapters, a public `Window` type. `App.window()` returns an unexported `*windows.Window`.

### Input and commands

GPUI's command system is the one an editor needs: typed `Action`s, `key_context("Editor")`, JSON keymaps, multi-key sequences, nested capture/bubble, local bindings beating workspace bindings.

Zircon UI has `Keymap(Action)` for single chords, linear scan, and a small `Key` enum. Digits, F-keys, and most punctuation collapse to `.unknown`. Multi-stroke and context maps are listed as remaining work. The editor currently papers over this in `apps/zircon`.

### Animation and tasks

Both have springs and tweens. Zircon UI's keyed scalar tracks (entity × key), presence opacity, reduced-motion snap, and "tick only while active" policy are clean.

GPUI's executor is richer: foreground versus background, `AsyncApp` across await, test-controlled time. Zircon UI uses a thread-per-job queue with cooperative cancel, owner-tied completion, and `App.wake()` for external inboxes. The job contract (`run` / `discard` / optional `deinit`) is excellent. It is not an async runtime.

### Testing

Zircon UI is unusually contractual for a 6k-line framework.

- Same `App.step` / `dispatch` path in headless and native
- Compile-fail fixtures for mutable render, borrowed reads, invalid handlers
- Allocation-failure injection in entities, frames, layout, tasks
- Native AppKit, Metal, and CoreText suites
- Fresh sequential native journeys (`test-native-fresh`)
- Explicit foreground versus `NSWindow.sendEvent` routing logs

GPUI has `#[gpui::test]` and simulated input. Zed's tests are large. Zircon UI's tests are a better public contract than GPUI's README-level story.

### Accessibility

GPUI has a real AccessKit tree, roles, synthetic children for custom editors, and platform adapters. Zed's application path is still experimental and off by default (`ZED_EXPERIMENTAL_A11Y=1`). Framework infrastructure exists. Product coverage is incomplete.

Zircon UI has focusable controls and Tab. No accessibility tree. On X, people already call GPUI the weakest of the Rust GUI frameworks on accessibility. Zircon is behind even that.

### GPUI as a library

GPUI is production-quality as Zed's UI. As a public library it is pre-1.0, documented as "read Zed or ask Discord," and split across `gpui`, `gpui_platform`, and per-OS crates. crates.io `gpui` 0.2.2 is stale relative to `main`. Unofficial republishers (`gpui-unofficial`, `gpui-ce`, `gpui-x`, bite-gpui) are not interchangeable. Contributions still go through the Zed monorepo.

Zircon UI is a local 0.1.0 path dependency with a written API map. That is easier to learn and easier to break. There is no external consumer policy yet.

## Editor comparison

Side by side, the chrome is intentionally Zed-like: One Dark roles (`#282c33` document, `#3b414d` chrome, `#74ade8` accent), 34 px titlebar, 32 px tabs, native traffic lights, project and branch in the title, compact status bar. Captures against Zed Preview 1.28 show the same hierarchy. This is a visual and interaction pass, not pixel parity. See [zed-ui-reference](zed-ui-reference.md) and [inspection](../reviews/zed-ui/inspection.md).

Zed's window is more finished: fold carets, inline blame on the current line, richer syntax, a Git dock that can sit beside the tree, more status items that are actually wired. Zircon's window is already a compact professional editor. Syntax is seven token classes. The Git gutter is a continuous strip. The status bar is dense.

### Feature matrix

"Working" means connected behavior with source or test evidence. "Partial" means useful scope with material limits.

| Area | Zed | Zircon |
| --- | --- | --- |
| Text storage | Sum-tree rope, CRDT, collaboration | AVL rope, 4 KiB leaves, snapshots, grouped undo |
| Multi-cursor | Full, next/all occurrences | Working core |
| Soft wrap | Background display map, grapheme-aware | Cached visual rows. Width/font still scan. Code-point |
| Folding | Syntax-aware | Indentation, skipped above 8 MiB |
| Vim | Broad subset plus Helix. Macros, objects | Real Normal/Insert/Visual/Block. No macros, Ex, or marks |
| IME | Implemented plus tests | Selectors and revision checks. OS acceptance open |
| Graphemes | Wrap and movement work exists | Code-point movement |
| File encodings | encoding_rs, BOM, UTF-16 | UTF-8 and CRLF |
| Save / conflicts | Watchers, auto-reload, overwrite UI | Atomic sibling save, SHA-256 fingerprint, `DiskConflict` |
| Crash recovery | Session restore | Store implemented. Not wired through restart |
| File tree | Create, rename, move, delete | Open, drag, virtualize. No rename, delete, or new-folder |
| Panes | Nested trees, docks | Two groups, four-edge drop |
| Git | Hunk stage, conflicts, graph, watchers, worktrees | File-level stage, commit, history, blame, stash, push. Inline hunk display. No hunk stage, conflict editor, or auto-refresh |
| Search | Regex project search, editable multibuffers | Buffer regex. Project literal. Opens the original file |
| LSP | Hover, definition, references, rename, format, code actions, semantic tokens | Diagnostics and completion. Full-document `didChange` |
| Tree-sitter | Incremental, injections | WASM grammar, full reparse up to 8 MiB |
| Extensions | WASM WASI, themes, language servers, snippets, DAP, MCP, agents | Official catalog plus themes, icons, grammars, WASM language-server hooks. No snippets, DAP, or MCP |
| Terminal | Full emulator, tasks, clickable paths | Real PTY tabs, basic ANSI |
| Agent | Zed Agent, ACP, edit prediction, worktrees, MCP | Codex and ACP clients, permissions, text attachments |
| Debugger | DAP, several adapters | Absent |
| Collaboration / remote | Channels, SSH, containers | Absent |
| Settings | Large catalog, live, context keymaps | Small set, child window, single-stroke bindings |
| Platforms | macOS, Linux, Windows | macOS native |
| Distribution | Signed channels | Local ad-hoc signed `.app` |

The November 6 [audit](zircon-vs-zed-audit-2026-11-06.md) remains the row-by-row evidence log. Terminal, two pane groups, wrapping, and several Git/UI passes landed after that date. Treat this table as current source, and the audit as the earlier detailed matrix.

### Where the editor is strong

**Text model.** `apply(expected_revision, sorted disjoint ranges, group)` validates and allocates before swapping the root. Undo restores a content-state identity separate from revision, so undo-to-saved is clean. Snapshots are immutable and share nodes. Workers may only read a retained snapshot.

**Workspace identity.** Canonical paths, symlink alias dedup, atomic save with `fsync`, POSIX mode preservation, SHA-256 plus inode fingerprints, dirty-close policy. Conflict checks are optimistic at the final rename, which the code states.

**Revision hygiene.** Git gutters, grammar spans, completions, search stamps, blame, and jobs all carry generations. A retired frame cannot stage the wrong path. Stale language-server diagnostics are refused.

**Git at file granularity.** Status tree, working/staged/untracked, commit, history patches, continuous gutters, inline hunk expansion (display-only), delayed blame with hover and Copy SHA, branch create/switch, fetch/pull/push, stash.

**Package boundaries.** Domain packages import the standard library. Git, ropes, language-server framing, and search can be tested without a window.

**Extension isolation.** `zircon-extension-host` is a locked Rust worker process. Catalog, install, Tree-sitter highlight, and WASM `init-extension` run out of process. A grammar crash does not take the UI with it. The lockfile does not compile Zed's GPL crates.

**Documentation.** Status, roadmap, remaining-work tables, benchmark method, and native verification procedure refuse to claim Zed-beating speed.

### Measured Zircon baseline

From the [40/40 lifecycle baseline](../benchmarks/editor-2026-11-07-lifecycle-current-git/README.md). ReleaseFast, Mac15,12, 16 GiB, 20 insert/backspace events, p95 to native frame submission.

| File | Wrap | Configuration | Median p95 submit | Sampled tree RSS |
| --- | --- | --- | --- | --- |
| 32 KiB | Off | Core | 1.71 ms | 91.5 MiB |
| 32 KiB | On | Services | 1.28 ms | 114 MiB |
| 1 MiB | Off | Services | 2.88 ms | 308 MiB |
| 1 MiB | On | Core | 13.20 ms | 99 MiB |
| 1 MiB | On | Services | 10.82 ms | 313 MiB |

Unwrapped typing sits inside an 8–16 ms frame. Wrapped 1 MiB is the cliff: wrap-map rebuild on the UI thread. Services at 1 MiB also cost about 300 MiB RSS and fire repeated Git status/history plus full-document language-server changes. Zed's display map and incremental parse exist specifically to avoid that cliff.

The method excludes physical key-to-pixels, GPU scanout, and Zed ranking.

## X discussion, 2026

These are public posts, not measurements.

- Zed still pitches GPUI as a 120 fps, game-style renderer with no Chromium tax ([@zeddotdev, 2023 thread still cited](https://x.com/zeddotdev/status/1633852088433139713)). Users in 2026 still report that the editor "zooms" and that VS Code looks heavy next to it.
- Jason Lee ([@huacnlee, 2026-10-07](https://x.com/huacnlee/status/2107659622672937117)) published GPUI Fast: same API, more retained work, 40–70% CPU down to 10–25% CPU at 120 FPS on a scrolling benchmark. Immediate trees have a real cost.
- Marc-André Moreau ([@awakecoding, 2026-11-05](https://x.com/awakecoding/status/2118315373682725235)): Zed built GPUI for itself and does not intend to maintain it full-time for everyone.
- Accessibility: community comments still rank GPUI last among Rust GUI frameworks.
- Docs and onboarding: people publish GPUI Kit guides, skills, and starters because the official path is "read Zed." Ariel Conti called the missing docs painful compared with other tools (2026-11-04).
- Compile time: Arnav Gupta and others describe Rust compile loops as unusable next to LLM token rates. That is a product argument for staying in Zig.
- Zed versus VS Code: speed, native feel, and built-in Git/AI win praise. Marketplace, debugger long tail, and extension UI remain VS Code's wall. Zed's own extension model cannot draw arbitrary UI.

## What is better in this tree

### Framework

1. Ownership is a contract. Generational handles, scopes, snapshot-only reads, runtime borrows, deferred destroy. Failures are `BorrowConflict`, `WrongThread`, `EntityNotFound`.
2. Const render. Mutation during `render` cannot compile.
3. Frame rollback as a law. Failed staging keeps the last good tree, scene, handlers, and IME target.
4. Typed `Style` instead of a fluent chain. Invalid lengths and colors fail validation.
5. No C or Objective-C sources. Comptime `objc_msgSend` is a Zig showcase.
6. Job ownership. Entity-owned workers, cooperative cancel, suppress-on-destroy, `discard` after completion. Producers call `App.wake()` and never touch entities.
7. Testability. Headless `step`, compile-fail contracts, native pixel and selector tests, allocation-failure paths.
8. Explicit bounds. 8 MiB retired arenas, 4 MiB atlas, 64 MiB files, 262k instances. Fail closed. Zed is more unbounded and has had language-server memory blow-ups in the wild ([discussion 59303](https://github.com/zed-industries/zed/discussions/59303)).
9. Size. A competent Zig developer can read `zircon_ui` in a day.
10. Compile iteration. Zig 0.17.1 stays cheap if the graph stays small. The Rust extension host is a worker, not a second application.

### Editor

1. Cleaner module graph. UI-independent domain packages.
2. Out-of-process extension host.
3. Revision-checked completions, diagnostics, Git rows, grammar spans, and search stamps.
4. Atomic save plus content-state dirty flag. Undo to saved is clean.
5. Catalog reuse. Real Zed themes, icons, and grammars install. Users do not start from zero languages.
6. Honest docs. No speed claim without a method.

## What to improve

Ordered by leverage. The [roadmap](../editor-roadmap.md) already names most of this. M1 is recovery, Unicode, and sync. M2 is navigate, format, search, and build.

### Daily coding loop

1. Language navigation. Hover, go to definition, references, outline. Completion without those is a notepad with a popup.
2. Format and rename. Version-checked workspace edits, one undo.
3. File watchers and recovery. External `git checkout` and crash restore are daily use. The recovery store exists. Wire it through restart.
4. Project search and replace. Regex, path filters, replace preview. Opening the original file is acceptable as v1. Editable multibuffers are later.
5. Hunk staging and conflict UI. File-level Git is already good. Hunks are what people use.
6. Graphemes and real IME. Combining marks, flags, CJK composition on a foreground window.
7. Incremental wrap and parse. The 13 ms wrapped-1 MiB cliff is the first performance bug that matters. Persistent grammar workers, incremental wrap map, stop Git-on-every-keystroke.
8. File tree mutations. New file and folder, rename, delete, with identity updates for open buffers.
9. Async open and save. 64 MiB synchronous flatten will hitch.

### Framework API

Keep the counter-shaped API. Deepen it. Do not copy Tailwind.

1. True three-phase custom elements with `layoutChild`. Today `prepaint` is folded into `paint`, and custom nodes are leaves. That blocks reusable lists, popovers, and a scroll view.
2. Stock controls with keyboard and accessibility contracts. List, toggle, menu, popover, scroll view. `apps/zircon` already reinvents them.
3. `uniform_list` as a control. `visibleRows` is math. GPUI's `uniform_list` is why a project panel stays at 120 Hz.
4. Actions and context keymaps. Single-chord `Keymap` cannot express `g d` or `Editor && vim`. Widen `Key` first (digits, F-keys, punctuation).
5. AccessKit or AX directly. Even a button, text field, and editor subset. Zed being incomplete is not a reason to ship zero.
6. Public `Window`. `setTitle`, `requestFrame`, `choosePath` as App-level APIs.
7. Scene primitives chrome will need: shadows, underlines, color glyphs. Paths and SVG can wait until a screen requires them.
8. View or subtree cache later, after measurement. The 1 MiB wrap cliff is the editor, not the chrome.
9. Flex wrap and grid when a real screen needs them. Editor wrap stays in the editor package.
10. Platform adapters after the macOS editor is dependable. Portable compile is not Linux.

Small API cleanups:

- Two different `LayoutResult` types in `root.zig`
- `controls.Scroll` is offset math, not a widget
- Animation keys are raw `u64`s that alias when multiplied by 4
- Window slot list never reclaims. Bump generation or reuse
- `button` as both label and container is powerful. Document it as the chrome pattern

### UI

Further chrome cloning will return less than interaction quality.

- Native menu bar and save dialogs
- Tab overflow, MRU, back/forward history. The chevrons currently switch adjacent tabs
- Problems panel and diagnostic squiggles
- Keyboard-complete every overlay
- Keep the existing narrow-window tests
- Theme tokens are 11 UI plus 7 syntax. Imported Zed themes lose richness. Expand tokens before chasing new chrome
- Color emoji and ligatures in the atlas if the goal is the native Mac editor feel Zed has

### Performance work to measure next

Keep the existing method.

1. Incremental wrap
2. Persistent Tree-sitter worker
3. Incremental language-server sync
4. Git refresh coalesced on repository events
5. Process RSS with services on
6. Then a Zed side-by-side on the same machine

### Product boundary

Zed has collaboration, a debugger, remote development, a full agent IDE, and three desktop platforms. Chasing that list is how this project loses.

A dependable local Zig-native editor that installs Zed grammars and talks ACP is a coherent product. A seventy-percent Zed clone is not.

Zed extensions cannot draw UI. If Zircon ever grows plugins, custom views would be a differentiator and a security surface. Do not start there.

## Architecture snapshot

```
Zed                                      Zircon
----                                     ------
PlatformWindow::draw(Scene)              Metal present(Scene)
GPUI: Render → Taffy → prepaint → paint  zircon_ui: staging tree → flex → paint → swap
Workspace Entity                         Shell entity
Editor Entity + EditorElement            zircon_editor.Editor + Canvas custom leaf
MultiBuffer → language::Buffer           zircon_workspace.DocumentId
text::Buffer (CRDT rope)                 zircon_text AVL rope
DisplayMap (wrap/fold/inlay)             wrap.zig cache + indent fold
BackgroundExecutor                       cx.spawn + extension-host process
WASM in-process                          zircon-extension-host (Rust, out of process)
AccessKit                                (none)
```

GPUI does not know what a buffer is. Zircon already copied that split. Keep it.

## Assessment

Zircon UI is a serious, small, Zig-native GPUI. Its ownership, rollback, testing, and native bindings are better designed for Zig than a straight port would have been. It is an editor host, not a general UI toolkit. Missing: accessibility, wrapping layout, stock controls, other operating systems, and a real command system.

Zircon the editor is a capable macOS preview: real files, real Git at file level, real completions, real Zed catalog, real PTY, real agent clients, chrome that already looks like the reference. It is not yet a dependable daily editor. Watchers, recovery, language navigation, graphemes, hunk Git, and project replace are how people actually work.

Protect the entity, snapshot, and job contracts. Protect the package split, the test culture, and the refusal to claim speed without numbers.

Build the M1 and M2 loop next. Pull framework work from those screens: lists, menus, accessibility, context keymaps, `layoutChild`.

## Sources

Local: this repository's packages, `docs/zircon-ui.md`, `docs/status.md`, `docs/editor-roadmap.md`, `docs/zed-extensions.md`, `docs/benchmarks/editor-2026-11-07-lifecycle-current-git/README.md`, `docs/reviews/zed-ui/inspection.md`.

GPUI: [README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md), [gpui.rs](https://gpui.rs/), [contexts](https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/contexts.md), [key dispatch](https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/key_dispatch.md), [accessibility](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/_accessibility.rs), [scene](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/scene.rs), [ownership blog](https://zed.dev/blog/gpui-ownership), [120 FPS blog](https://zed.dev/blog/videogame).

Zed: [1.0 post](https://zed.dev/blog/zed-1-0), [git docs](https://zed.dev/docs/git.md), [debugger](https://zed.dev/docs/debugger.md), [vim](https://zed.dev/docs/vim.md), [extensions](https://zed.dev/docs/extensions/developing-extensions.md), [AI overview](https://zed.dev/docs/ai/overview.md), stables 1.26–1.27 (Oct–Nov 2026).
