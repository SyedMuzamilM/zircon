# Implementation status

Audited on 2026-11-06 against the preserved [framework specification](specification/framework-api-v0.1.md), [editor requirements](specification/editor-experience.md), source and executable checks. Zircon UI and the editor run natively on macOS using direct Zig system bindings and Metal. NanoUI and GPUI remain research references, with no implementation dependency or C/Objective-C bridge source.

The framework supports these editor workflows. It does not implement the entire proposed framework API, and the editor does not have full Zed parity. A percentage would hide the different sizes of the remaining features.

## Framework coverage

| Area | Implemented and exercised | Remaining scope |
| --- | --- | --- |
| State | Typed generational entities, ownership scopes, scoped borrows, deferred destruction, observations/events, dependency invalidation | Broader load/adversarial validation |
| Views | Const views, indexed/keyed committed and staging trees, rollback, composed buttons, three-phase custom elements, composed hover states, centered button labels and themed search fields | More stock controls and accessibility metadata |
| Rendering | Flex subset/stacks, CoreText glyph geometry, Metal ordered text/rect/image/round-capped-line batches, clipping/rounding, scroll-aware layout and hit geometry, virtual range clamping after content shrinks, PNG snapshots, retained images and texture leases | General SVG/path rendering, grid/baselines, color emoji, GPU recovery. Editor-specific soft wrapping and shared panel shadows exist |
| Native runtime | AppKit windows, integrated titlebars and native controls, drag regions, parent/child settings windows, input capture/target/bubble, focus/capture/modal scopes, clipboard and revisioned IME selectors | Native menus/dialogs, full OS input-method acceptance, accessibility, more shortcut forms |
| Motion/tasks | Keyed tweens/springs/color/geometry/presence, reduced motion, deadline-driven carets, entity-owned workers, external inbox drains with coalesced native wake events | Application-wide animation polish and further cancellation/load testing |
| Resources/platforms | Bounded glyph/text/texture caches, 8 MiB retention budget per retired frame arena, Linux portable cross-compilation | Whole-process benchmarks and Windows/Linux native adapters |

Active frames and in-flight GPU leases can exceed retention/cache budgets. These policies do not cap process memory. Large selected text can still enlarge native surrounding-text snapshots. No speed, executable-size or memory advantage over Zed has been measured.

## Editor coverage

| Requested area | Working behavior | Practical limits |
| --- | --- | --- |
| Workspace UI | Integrated titlebar, native traffic lights, project tree, file headings, tabs, palette, status, dirty-close protection | No native application menu or terminal/debugger/collaboration |
| Documents | Persistent UTF-8 rope/snapshots, safe saves/conflicts, multi-cursor selection, clipboard, grouped undo/redo, local find/replace | Code-point rather than grapheme movement; no bidi/soft wrap; a logical line above 64 KiB shows a display notice; synchronous file I/O capped at 64 MiB |
| Vim | Normal/Insert/character, line and block Visual modes, native input suppression, block cursor, counts/operators, word objects, literal search, register/paste, grouped undo and supported edit repeat; printable command remaps | Initial command set listed in the guide; no macros, Ex, named registers, marks, arbitrary text objects or full grapheme motion |
| Dragging/splits | Pointer-captured tab reordering, project-file dragging, right-side split drops, resizing dividers, independent selections on shared documents, cancellation | Two panes with left/right/up/down actions and a split menu; no arbitrary nested pane trees or OS file drops |
| Extensions | Official Zed catalog, supported package install/update/activation/removal; theme/icon conversion; Tree-sitter grammars; WASM LSP hooks; 13 common-language providers | Partial Zed API/contribution support. See [compatibility](zed-extensions.md); registry visibility is not universal certification |
| Git | Changes/History tabs, collapsible conflict/tracked/untracked folder rows, per-file staging checkboxes, working/staged patches including untracked additions, stage/unstage/all, commit messages and real commits, history/selected commit patches with per-file headings, source line numbers and lexical highlights, unsaved gutters, continuous diff strips, inline hunk expansion with old/current lines and intraline highlights, centered current-line blame labels and scrollable hover cards with Copy SHA, local/remote branch selection/creation, fetch/pull/push/publication, stash save/apply/pop/review and combined HEAD-to-worktree review | File-level staging; no hunk staging, conflict-resolution editor, destructive restore/discard menus or operation cancellation. Refresh is explicit/on editor events; commands have bounded time/output and cannot cancel mid-command |
| Search | Project files and current unsaved/untitled buffers, grouped context/counts, source revision/stamp checks, source selection and editing | Excerpts open the real source for editing. Direct combined-excerpt editing, regex and automatic live query refresh remain work |
| Content | Native image viewing; source-linked Markdown headings/paragraphs/lists/quotes/code/tables/links/local images; preview updates beside source, generation/width/font/color keyed layout caching, offscreen draw culling and decoded-image reuse | First image frame, fit-to-window viewing; no image editing/zoom. Markdown is a subset, without CommonMark conformance or HTML execution; parsing and invalidated layouts remain synchronous, without block virtualization; remote images are not fetched |
| Language services | Persistent stdio processes, initialize/open/change/close, versioned diagnostics/navigation, revision/session/URI-checked completions and additional edits, shutdown on extension disable | No snippets, semantic tokens, formatting, rename, hover, definition or workspace edits. Optional diagnostic versions are accepted only against a still-current document version. Fixture server, Apple clangd, official ZLS and Pyright journeys accepted |
| Settings | Separate integrated child window above workspace, search/categories, persisted System/Light/Dark themes, icons/installed font family/tab width/line-number/gutter/blame/reduced-motion/Vim choices, shared updates, new-pane inheritance and bounded JSON workspace shortcuts | Small working settings set; no keybinding editor |

See the [editor guide](editor-guide.md) for controls and package ownership. [Experience design](design/experience.md) records lifetime and revision contracts.

## Verification

```sh
./tools/zig build check
./tools/zig build test-editor-native
./tools/zig build test-settings-native
./tools/zig build test-language-real
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
./tools/zig build -Doptimize=ReleaseFast
```

`check` runs portable framework, document, workspace, editor, Git/parser, extension, search, Markdown, language-client and application suites, formatting and three expected compiler-error contracts. Native suites run sequentially. The settings-opening regression sends a synchronous AppKit blur during a borrowed workspace action, then opens settings through native mouse and Cmd+, events. It checks visibility, parent centering and reopening. App tests filter settings by typing, scroll and click the bottom toggle, reopen the persisted store, and open settings.json in the workspace. They exercise AppKit/CoreText/Metal objects, decoded image/GPU pixels, titlebar controls, settings parenting, editor input and saved bytes.

Application journeys use temporary repositories and directories. They stage/unstage/commit, inspect history, show unsaved gutters/blame, activate/disable extensions, reorder/drop tabs, search saved/unsaved buffers, update preview source, decode an image, accept Unicode completion and undo it. Protocol fixtures cover fragmented framing, reversed responses, stderr pressure, malformed/blocked processes and teardown. `test-language-real` separately accepts a completion from installed Apple clangd into the original C document. Regressions also check that equal request IDs from different servers cannot reach the wrong document.

macOS currently does not grant the unattended test process foreground activation in this session. Tests route native keys through `NSWindow.sendEvent` and its real first responder when activation is unavailable, and retain queued-application routing when it succeeds. The mode is recorded in `/tmp/zircon-native-input-mode.txt` and `/tmp/zircon-editor-input-mode.txt`. These checks establish native routing/selectors, without establishing full foreground or OS IME acceptance.

Native screenshots are written to `/tmp/zircon-vim-visual.png`, `/tmp/zircon-editor-initial.png`, `/tmp/zircon-settings.png`, `/tmp/zircon-git-changes.png`, `/tmp/zircon-git-all.png`, `/tmp/zircon-git-history.png`, `/tmp/zircon-inline-blame.png`, `/tmp/zircon-project-search.png`, `/tmp/zircon-extensions.png`, `/tmp/zircon-markdown.png`, `/tmp/zircon-image.png`, `/tmp/zircon-completion.png` and `/tmp/zircon-clangd.png`. Framework PNGs contain framework content; native traffic lights are checked through their AppKit objects.

Layout regressions check that status buttons fit their bar, long messages keep Settings visible, and narrow utility tabs retain their trailing controls. Framework checks cover centered labels, themed input geometry and hit testing, virtual ranges after content shrinks, and hover entry/exit through native AppKit events. Git journeys collapse folders, toggle staging checkboxes, switch comparisons, inspect a multi-file/untracked patch, and verify comparison refresh after staging.

The compact workspace chrome, original outline icons, settings navigation and Git panel follow the [pinned Zed source study](research/zed-ui-reference.md) and preserved screenshots. This is a visual and interaction pass, without claiming pixel-perfect or complete Zed parity.

The [benchmark method](benchmarks/method.md) remains an intended measurement protocol. No comparative benchmark results are claimed. The supplied specification remains unchanged.

The November 6 consistency pass reproduces native typing through AppKit in search, command, path, find and replace fields, including accented text and emoji. It corrects Foundation's signed `NSNotFound` sentinel. New journeys cover four split directions, vertical resizing, 120-pixel sidebars, shortcut override/unbinding and rejection, system appearance callbacks, native chrome appearance, delayed compact blame, full commit-body retrieval, SHA copying and uncommitted-line behavior. A subsequent pass separates hover blame from inline hunk expansion and makes commit messages scrollable. Multi-stroke/context keymaps, arbitrary pane nesting and commit permalinks remain work. See [the source-backed feature priorities](research/zed-feature-priorities.md) for Zed references and public request evidence.

The gutter/Git follow-up uses SVGs under `assets/icons` as the single icon source. The offline generator preserves fills, holes, opacity and source stroke widths; `python3 tools/generate_icons.py --check` checks synchronization. Zed and Lucide source revisions and ISC notices ship alongside the assets, with notices installed under `share/zircon`.

Validation covers continuous multi-row markers, source mapping at start/middle/EOF deletions, UTF-8 intraline ranges, hover metadata alignment and dismissal, inline expansion without edits, branch creation, dirty-buffer refusal, clean-buffer reload after stash, searchable choice selection/cancellation, and real fetch/pull/push against a disposable bare remote. Stash tests check tracked/untracked inclusion and retention on conflicting Pop. Native journeys use a hidden native editor window and send synthetic keys to its actual NSWindow, avoiding foreground keyboard interference.


The editing follow-up checks the [pinned Zed Vim and rendering sources](research/zed-vim-editing-performance.md). Regressions first reproduced Cmd+Delete leaving source unchanged, a Markdown scroll performing two additional full layouts, and cached Git-file navigation starting another job. The fixed journeys assert the resulting bytes, zero extra scroll layouts, width invalidation, stable decoded-image identities across text edits and an unchanged Git generation on navigation. These counts establish removal of redundant work, without claiming a measured wall-clock speedup or Zed comparison.

Vim tests cover count/operator combinations, inclusive reversed visual ranges, line/block transactions, rectangular paste and insertion, word changes and dot-repeat, Unicode Insert text, stale native edits, CRLF/EOF and deterministic mixed-command sequences. Native NSWindow events check that Normal/Visual publish no editable text snapshot, Insert restores one, typing changes the expected bytes and undo restores the modal cursor. Core Text tests enumerate real installed families and check resolved PostScript names after choosing them. Arranged menu bounds are checked against their invoking pane and after narrow-window resize.

The [Zed compatibility journey](zed-extensions.md) additionally verifies official Zig grammar execution, real ZLS/Pyright completions, acceptance/undo, theme/icon changes, wrapped rows, catalog search and remote installation. Word wrap uses a cached source-to-visual row map. Unit tests compare incremental updates with a fresh map and validate continuation-row pointer/arrow navigation. This does not establish Zed-wide language-service parity or performance targets.
