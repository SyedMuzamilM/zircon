# Implementation status

Audited on 2026-11-06 against the preserved [framework specification](specification/framework-api-v0.1.md), [editor requirements](specification/editor-experience.md), source and executable checks. Zircon UI and the editor run natively on macOS using direct Zig system bindings and Metal. NanoUI and GPUI remain research references, with no implementation dependency or C/Objective-C bridge source.

The framework supports these editor workflows. It does not implement the entire proposed framework API, and the editor does not have full Zed parity. A percentage would hide the different sizes of the remaining features.

## Framework coverage

| Area | Implemented and exercised | Remaining scope |
| --- | --- | --- |
| State | Typed generational entities, ownership scopes, scoped borrows, deferred destruction, observations/events, dependency invalidation | Broader load/adversarial validation |
| Views | Const views, indexed/keyed committed and staging trees, rollback, composed buttons, three-phase custom elements | More stock controls and accessibility metadata |
| Rendering | Flex subset/stacks, CoreText glyph geometry, Metal ordered text/rect/image batches, clipping/rounding, PNG snapshots, retained images and texture leases | SVG/paths/shadows, wrapping/grid/baselines, color emoji, GPU recovery |
| Native runtime | AppKit windows, integrated titlebars and native controls, drag regions, parent/child settings windows, input capture/target/bubble, focus/capture/modal scopes, clipboard and revisioned IME selectors | Native menus/dialogs, full OS input-method acceptance, accessibility, more shortcut forms |
| Motion/tasks | Keyed tweens/springs/color/geometry/presence, reduced motion, deadline-driven carets, entity-owned workers, external inbox drains with coalesced native wake events | Application-wide animation polish and further cancellation/load testing |
| Resources/platforms | Bounded glyph/text/texture caches, 8 MiB retention budget per retired frame arena, Linux portable cross-compilation | Whole-process benchmarks and Windows/Linux native adapters |

Active frames and in-flight GPU leases can exceed retention/cache budgets. These policies do not cap process memory. Large selected text can still enlarge native surrounding-text snapshots. No speed, executable-size or memory advantage over Zed has been measured.

## Editor coverage

| Requested area | Working behavior | Practical limits |
| --- | --- | --- |
| Workspace UI | Integrated titlebar, native traffic lights, project tree, file headings, tabs, palette, status, dirty-close protection | No native application menu or terminal/debugger/collaboration |
| Documents | Persistent UTF-8 rope/snapshots, safe saves/conflicts, multi-cursor selection, clipboard, grouped undo/redo, local find/replace | Code-point rather than grapheme movement; no bidi/soft wrap; a logical line above 64 KiB shows a display notice; synchronous file I/O capped at 64 MiB |
| Dragging/splits | Pointer-captured tab reordering, project-file dragging, right-side split drops, resizing dividers, independent selections on shared documents, cancellation | Two side-by-side panes, without arbitrary nested pane trees or OS file drops |
| Extensions | Real local install/enable/disable/remove; semantic themes, symbol/PNG icons, lexical profiles and server configuration; deterministic fallbacks | Local contribution format, without a remote marketplace, executable plugin/WASM host or Zed compatibility |
| Git | Changed files, working/staged patches, stage/unstage/all, commit messages and real commits, history/selected commit patches, unsaved gutters, inline author/commit blame | File-level staging; no hunk staging, conflict editor or branch UI. Refresh is explicit/on editor events; commands have bounded time/output and cannot cancel mid-command |
| Search | Project files and current unsaved/untitled buffers, grouped context/counts, source revision/stamp checks, source selection and editing | Excerpts open the real source for editing. Direct combined-excerpt editing, regex and automatic live query refresh remain work |
| Content | Native image viewing; source-linked Markdown headings/paragraphs/lists/quotes/code/tables/links/local images; preview updates beside source | First image frame, fit-to-window viewing; no image editing/zoom. Markdown is a subset, without CommonMark conformance or HTML execution; remote images are not fetched |
| Language services | Persistent stdio processes, initialize/open/change/close, versioned diagnostics/navigation, revision/session/URI-checked completions and additional edits, shutdown on extension disable | No snippets, semantic tokens, formatting, rename, hover, definition or workspace edits. Unversioned diagnostics are ignored. Fixture server and installed Apple clangd accepted; ZLS-specific behavior is not yet accepted |
| Settings | Separate integrated child window above workspace, search/categories, persisted theme/icons/font/tab width/line-number/gutter/reduced-motion choices, shared updates and new-pane inheritance | Small working settings set; no keybinding editor |

See the [editor guide](editor-guide.md) for controls and package ownership. [Experience design](design/experience.md) records lifetime and revision contracts.

## Verification

```sh
./tools/zig build check
./tools/zig build test-editor-native
./tools/zig build test-language-real
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
./tools/zig build -Doptimize=ReleaseFast
```

`check` runs portable framework, document, workspace, editor, Git/parser, extension, search, Markdown, language-client and application suites, formatting and three expected compiler-error contracts. Native suites run sequentially. They exercise AppKit/CoreText/Metal objects, decoded image/GPU pixels, titlebar controls, settings parenting, editor input and saved bytes.

Application journeys use temporary repositories and directories. They stage/unstage/commit, inspect history, show unsaved gutters/blame, activate/disable extensions, reorder/drop tabs, search saved/unsaved buffers, update preview source, decode an image, accept Unicode completion and undo it. Protocol fixtures cover fragmented framing, reversed responses, stderr pressure, malformed/blocked processes and teardown. `test-language-real` separately accepts a completion from installed Apple clangd into the original C document. Regressions also check that equal request IDs from different servers cannot reach the wrong document.

macOS currently does not grant the unattended test process foreground activation in this session. Tests route native keys through `NSWindow.sendEvent` and its real first responder when activation is unavailable, and retain queued-application routing when it succeeds. The mode is recorded in `/tmp/zircon-native-input-mode.txt` and `/tmp/zircon-editor-input-mode.txt`. These checks establish native routing/selectors, without establishing full foreground or OS IME acceptance.

Native screenshots are written to `/tmp/zircon-editor-initial.png`, `/tmp/zircon-settings.png`, `/tmp/zircon-git-changes.png`, `/tmp/zircon-git-history.png`, `/tmp/zircon-inline-blame.png`, `/tmp/zircon-project-search.png`, `/tmp/zircon-extensions.png`, `/tmp/zircon-markdown.png`, `/tmp/zircon-image.png`, `/tmp/zircon-completion.png` and `/tmp/zircon-clangd.png`. Framework PNGs contain framework content; native traffic lights are checked through their AppKit objects.

The [benchmark method](benchmarks/method.md) remains an intended measurement protocol. No comparative benchmark results are claimed. The supplied specification remains unchanged.
