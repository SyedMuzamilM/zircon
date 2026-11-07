# Zircon compared with Zed

Audited 2026-11-06. Zircon commit `cc199756e303012e4f6dcee0330568fd6d8b2831`. Zed upstream main `e231594b6b8818ea8d668ee2eb73e1fb09300654`. This is a product and implementation audit, with local test execution, not a comparative performance benchmark.

## Assessment

Zircon has a working native editor foundation and a surprisingly broad set of connected workflows. Its text model, transactional edits, revision checks, shared documents, Git gutters, extension lifecycle and native settings deserve to be kept. The main gaps are the workflows that make an editor dependable all day: automatic external updates, recovery after a crash, complete language navigation, project-wide search and replacement, file management, terminal/tasks, and predictable input under real macOS focus conditions.

The visual foundation already resembles a compact professional editor. Replacing the colors or rebuilding the chrome would deliver less value than improving navigation, completion, diagnostics, Git state clarity and keyboard access. The next milestone should make a medium-sized real project comfortable to edit, build, inspect and recover.

There is no evidence here that Zircon is faster, smaller in memory, or more correct than Zed overall. Zig, Metal, a rope and bounded caches are implementation choices, not performance results. Conversely, a missing feature does not mean the existing implementation is poor.

## Evidence and limits

The [current Zed capability survey](zed-current-capabilities-2026-11-06.md) contains primary links for every upstream area, including implementation limits. It reads official documentation from Zed's pinned repository because the rendered documentation site returned HTTP 403. The upstream release API returned v1.27.0, but the survey examines main. Features found on main must not automatically be described as present in that release or in the user's installed Zed binary.

For Zircon, this audit reads the actual source and current tests, then checks newer guides against older status notes. The status table still says soft wrap is absent, although `wrap.zig`, current settings, the compatibility guide and tests implement it. Older research also predates delivered splits, System appearance, shortcuts and blame improvements. The matrices below use current source rather than preserving those old gap lists.

Visual observations use existing Zed reference captures and freshly generated Zircon native journey captures. They establish layout observations on those fixtures. They do not establish pixel parity, foreground interaction across every workflow, or a fresh side-by-side run of the installed Zed application. Native frame snapshots omit OS traffic lights even where actual AppKit controls exist.

### Fresh verification

The ordinary build targets initially passed using cached test results. To avoid treating a cache hit as a fresh native check, this audit took the test commands printed by `zig build ... --verbose`, removed compiler server mode `--listen=-`, and executed them sequentially through `zig test`.

| Check | Result in this audit | Meaning |
| --- | --- | --- |
| `./tools/zig build check` | Passed | Includes formatting and expected compile-error contracts. Individual positive suites were also rerun below. |
| Portable framework | 105 passed | State, frame, rendering, input and task behavior. |
| Text / workspace / editor | 16 / 12 / 40 passed | Includes Unicode storage, edit history, save conflicts and editor behavior. |
| Git package / Git parser | 12 / 6 passed | Real repository operations and parser/diff coverage. |
| Extensions / search / language / Markdown / agent packages | 11 / 11 / 5 / 5 / 3 passed | These are their existing suite scopes, not certifications of every external provider. |
| Portable application | 54 passed, 2 skipped | Some behaviors require native UI; the native application suite ran separately. |
| Three compile-error fixtures | Rejected with expected errors | Intentional negative checks, not application test failures. |
| Native rendering/framework suite | 24 passed | CoreText, Metal, images and runtime checks. |
| Native application journeys | 44 passed | Includes Git, search, extensions, settings, agent fixtures, editing and folding journeys. |
| Native settings regression | 1 passed | Child window/focus regression. |
| Real installed clangd journey | 1 passed | Completion edited the original document. |
| Standalone native window suite | 6 passed, 1 failed, reproduced in two fresh runs | `TextDispatchFailed` at `packages/zircon_ui/src/platform/macos/window_test.zig:68`. |

The last failure is a concrete release concern. It occurs in the test that sends queued/native key input and expects exactly one key event and one `x` insertion. Its recorded mode said foreground application events; the native application journey recorded the fallback `NSWindow.sendEvent` route. The application journeys passing does not resolve the standalone failure. The audit has not isolated whether focus, event duplication, timing, or another routing issue causes it. Do not describe it as proven IME corruption or as a general inability to type. Resolve this discrepancy and rerun both routes before declaring native input reliable.

Raw portable and native rerun logs accompany this report under [verification evidence](evidence/zed-comparison-2026-11-06/README.md). No source changes were made to fix findings as part of this audit.

## Feature-by-feature comparison

"Working" means an actual connected behavior with source/test evidence. "Partial" means useful functionality exists but has material scope limits. "Missing" means no user-facing implementation was found in the audited paths. These are qualitative judgments, not a feature-completion percentage. A recommendation is distinct from a claim about current behavior.

### Text editing and documents

Upstream references: [editing code](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/editing-code.md), [Vim](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/vim.md), and the Unicode/file-input source links in the Zed survey. Local evidence: [text storage][text], [snapshots][snapshot], [document edits][document], [editor][editor], [wrap][wrap], [folding][folding], [workspace persistence][persistence].

| Feature | Zed | Zircon: what is done properly | Gap and recommendation |
| --- | --- | --- | --- |
| Text storage | Rope-based editor infrastructure and display projections | Working. Persistent UTF-8 AVL rope, 4 KiB leaves, byte/LF/UTF-16 summaries, immutable snapshots and structural sharing. | Keep this foundation. Measure end-to-end typing before considering a storage rewrite. |
| Edits and undo/redo | Transactional editing with multiple views | Working. Validates stale revisions, UTF-8, ranges and overlapping edits before publishing. Multi-edit transactions and grouped history exist. Saved content identity is separate from increasing revision. | Add acceptance coverage for every future edit source, including formatter, workspace rename and external reload. |
| Multiple cursors | Multiple selections, next/all occurrences and integration with other features | Working core. Multiple ranges, clipboard/edit commands and grouped undo are present. | Broader occurrence selection, rectangular-edit edge cases and future snippet behavior need explicit UX coverage. Do not assume every Zed selection command exists. |
| Split document views | Multiple panes with shared buffers | Working for two panes. Text/history are shared; selection/scroll are per pane; ordinary edit mappings update the other view. | Arbitrary pane trees, per-pane tab stacks and consistent keyboard focus cycling are further work. Verify undo/reload caret behavior across views separately from ordinary edits. |
| Soft wrap | Configurable wrapping and display maps | Partial, already implemented. Source offsets remain unchanged; cached visual rows support pointer/vertical movement and Git/blame geometry. | Row-index rebuilding still visits document lines after edits. Initial/width/font layout is synchronous. Wrapping is not grapheme-complete. |
| Folding | Structured/syntax-aware editor folding | Partial. Indentation ranges, matching closing lines, click targets, source-preserving folds and search-triggered unfolding work. | Uses indentation rather than Tree-sitter/LSP fold ranges, rescans after revisions, and stops above 8 MiB. |
| Comments and line operations | Language-aware editing commands | Working subset. Cmd-/ and Vim `gc` use imported comment rules; indentation and multiple cursors are respected. Duplicate/delete/join and word/line editing commands exist. | Broaden language-specific indentation, bracket pairing, surround and structural commands with deliberate acceptance tests. |
| Vim | Broad emulation, including macros and text objects, with documented differences from Vim | Partial but real. Normal/Insert/Visual/Line/Block, counts/operators, word objects, search, unnamed register and supported dot repeat; native insertion is suppressed in command modes. | Macros, Ex, named registers, marks/jump lists, arbitrary text objects and Unicode command arguments are missing. Treat a complete advertised subset as more valuable than claiming Vim parity. |
| Unicode cursor/deletion | Grapheme-related editor and wrap logic exists | Partial. UTF-8 and UTF-16 boundaries, surrogate rejection and CRLF steps are deliberate and tested. | Movement/deletion step code points. Combining accents, flags, skin tones and family emoji can split into user-visible fragments. Grapheme semantics are essential. |
| Bidirectional text | Some RTL layout exists; source explicitly lacks complete UAX #9 support | Incomplete. Shaping is not a complete bidi editor model. | Do not claim parity with a perfect Zed bidi implementation. Define a product support policy and separately validate mixed-direction movement and selection. |
| IME and native input | Marked text and platform UTF-16 input integration | Implemented selectors, marked ranges, revision checks and composition history. Native journeys cover accented/emoji input. | Foreground IME acceptance is unestablished, and the standalone dispatch test currently fails. Test Japanese/Chinese/Korean composition, dead keys, Option layouts and focus transitions on real foreground windows. |
| File encoding | BOM, UTF-16 and legacy encoding detection/metadata/re-encoding | Partial. UTF-8 is validated, and LF/CRLF bytes are preserved. | No comparable encoding picker/conversion flow. Show unsupported encoding explicitly; add UTF-8 BOM and UTF-16 policy before broad legacy support. Avoid accidental re-encoding. |
| Large files and long lines | Mature large-document mechanisms; no universal bound or superiority established here | Explicit limits prevent some unbounded work. Workspace open/save is capped at 64 MiB; lines above 64 KiB show a notice. | A large generated single-line JSON file can open but be unreadable. Add an explicit large-file mode and communicate reduced capabilities. |
| Save and disk conflicts | Automatic external-change detection and overwrite/discard/cancel flow | Working safety foundation. Atomic sibling publication, file sync, permissions, pre/post conflict checks, hashes and no-clobber creation. | Open/save/read/hash remain synchronous. Existing-file conflict protection is optimistic across final check/rename, as source states. No crash-recovery/session backup was found. |

### Language intelligence

Upstream references: [language configuration](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/configuring-languages.md), [navigation](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/finding-navigating.md), [diagnostics](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/diagnostics.md). Local evidence: [language service][language-service], [LSP transport][lsp], [extension compatibility][extensions-guide].

| Feature | Zed | Zircon: what is done properly | Gap and recommendation |
| --- | --- | --- | --- |
| Syntax highlighting | Tree-sitter and configurable semantic tokens | Partial. Real installed WASM grammar/highlight queries, revision/UTF-8 validation, plus lexical fallback. | Seven token classes lose theme/grammar richness. Injection queries and maintained incremental parse trees are missing. |
| Server lifecycle | Managed language servers and configuration | Working core. Persistent stdio processes, framing, stderr draining, shutdown, initialization/configuration and restart action. | Broaden capability negotiation, logs/status UI, save/file-watch notifications and server-specific compatibility checks. |
| Completion | Rich LSP completion/snippets | Partial. Ctrl-Space and member-dot requests, selectable results, text edits/additional edits in one undo transaction. Checks server, URI, request, revision and caret. | Snippets, richer documentation, stronger ranking/filtering and other trigger characters need work. Current implementation sends triggerKind 1. |
| Diagnostics | Inline/gutter/scrollbar/project/tab views and push/pull support | Partial. Versioned diagnostics, document navigation and fixture/real server journeys exist. | Add squiggles, severity counts, Problems list, related info and quick fixes. Unversioned push diagnostics cannot prove which source revision a delayed server used. |
| Definition/type/implementation/references | Supported where server provides them | Missing user-facing navigation. | Essential daily coding functionality. Add go/peek/reference results and back/forward history together. |
| Hover/signature help | Supported | Missing | Essential for understanding APIs without leaving the file. Must behave correctly near window edges and under stale results. |
| Rename and code actions | Workspace refactors, server-dependent | Missing | Add version-checked workspace edits across open and closed files, with previews and undo policy. This is more than adding a button to completion. |
| Formatting | LSP/external formatting and format-on-save | Missing | Essential. First support explicit format document/selection, then optional format-on-save with errors and revision protection. |
| Outline/symbols/call hierarchy | Current-file/project symbols and server-dependent hierarchy | Missing | Outline and project symbols are high-value navigation. Call hierarchy can follow core navigation. |
| Semantic tokens/inlay hints | Supported with configuration; semantic tokens default off in audited docs | Missing | Useful after core language navigation and formatting. Their absence should not delay a usable first release. |

### Git

Upstream reference: [Git documentation](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/git.md) and watcher/Git-store sources in the survey. Local evidence: [Git service][git-service], [repository package][git-root], [diff algorithm][git-diff], [Git process runner][git-process], [editor guide][guide].

| Feature | Zed | Zircon: what is done properly | Gap and recommendation |
| --- | --- | --- | --- |
| Status and changed-file tree | Repository-aware changes panel | Working. Tracked/untracked/conflict groups, collapsible directories and file checkboxes. Row actions carry status generation/identity. | Add automatic refresh and clearer freshness/progress indicators. Scope to active repository before future multi-root support. |
| Working/index/HEAD distinction | Multiple comparisons and editable project diff | Working comparisons. Worktree, staged and combined HEAD-to-worktree review exist; untracked additions appear. | UI must make clear which baseline is displayed and which saved content will stage. Combined net comparison is not an exact representation of index state. |
| Whole-file staging/commit | Built in | Working. Stage/unstage/all, message editor and actual commits. Hooks/signing remain active. | Unsaved bytes are not staged. Warn clearly or offer an explicit save-then-stage action. Keep file-level actions labeled. |
| Hunk staging | Per-hunk stage/unstage | Missing | Must-have for a serious integrated Git workflow. Validate index identity before applying a patch and refresh both comparisons afterward. |
| Inline gutters | Buffer-aware Git change markers | Working. Compares unsaved text against index; continuous strips and next/previous change. | Ordinary typing should not trigger repository-wide status/history work. Index changes must invalidate the baseline even when text revision is unchanged. |
| Inline hunk expansion | Inline review/editing tools | Working. Removed/current rows and intraline fills are a display projection and preserve bytes/undo/dirty state. | Add reliable source navigation and hunk actions; avoid implying expansion itself stages anything. |
| Blame | Current-line and detail UI | Working. Delayed annotations, unsaved contents, revision checks, scrollable commit details and Copy SHA. | Cache by repository baseline and document revision, isolate from long mutations, and add resolvable commit permalinks later. |
| Diff viewing | Editable excerpts, split default and unified option on audited main | Partial. Numbered/syntax-colored unified patches and multi-file headers. | No equivalent side-by-side mode or direct editing of combined diff excerpts. Side-by-side is useful; editable multibuffers are larger scope. |
| History | File history plus Git Graph on audited main | Partial. Latest 100 commits and selected commit patches. | No comparable file-history workflow, pagination or graph was found. File history is more urgent than a graph. |
| Branch/remotes | Branch and remote operations, tags/worktrees | Working subset. Searchable local/remote branches, create/track, fetch/pull/push/publish and force-with-lease action. | Branch deletion/tags/worktree UI are absent. Long operations need visible progress/cancellation and credential-error recovery. |
| Stashes | Create/view/apply/pop/drop | Working subset. Tracked/all variants, patch review, apply/pop, retain stash on conflict. | Drop UI and fuller management are missing. Existing dirty-buffer protection is valuable and should remain. |
| Merge conflicts | Region choices/manual edits, then stage/commit | Conflict detection/listing exists | Missing conflict-resolution editor/actions. Provide ours/theirs/both plus manual editing and unresolved-marker checks; three-way layout can follow. |
| External Git changes | Watcher-driven repository/diff-base updates | Partial. Explicit refresh and editor-event refresh exist; own branch/pull/stash operations reload clean files. | External `git add`, checkout, reset, stash or another app can leave UI/baselines stale. This is a must-fix daily-use gap. |
| Discard/restore | Git UI has restoration operations | Missing destructive restore/discard UI | Add with a preview/confirmation and clear saved-versus-unsaved semantics. Do not make this the first Git improvement. |

### Search, files and workspace

Upstream references: [navigation](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/finding-navigating.md), [multibuffers](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/multibuffers.md), [project panel](https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/project-panel.md). Local evidence: [buffer find][buffer-find], [project search][project-search], [search engine][search-engine], [project index][project-index], [project UI][project-ui], [chrome][chrome], [settings][settings].

| Feature | Zed | Zircon: what is done properly | Gap and recommendation |
| --- | --- | --- | --- |
| Find/replace in file | Regex, case, word, selection scope and navigation | Working subset. Inline UI, Unicode regex/captures, 60 ms debounce, obsolete-result rejection and replace-all as one undo. Truncated results disable replace-all. | 8 MiB/20,000-match limits; selection-only scope and persistent worker are further work. |
| Project search | Regex/path filters/replacement, editable excerpts | Partial. Unsaved/untitled buffers override disk; source identities/stamps prevent stale-offset navigation; grouped excerpts and counts. | Project regex, path include/exclude, replace preview/apply and live refresh are absent. Local regex support does not imply project regex support. |
| Ignore behavior/index | Worktree-aware includes/excludes and deferred scanning | Partial. Background cancellable scan skips symlinked directories and several generated folders. | Hard-coded exclusions are not `.gitignore` support. A valid project may be incompletely indexed at 20,000 files or depth 32. Report coverage, allow configuration and watch changes. |
| File finder/palette | Fuzzy/context-aware action and file discovery | Working UI and shared actions. Shortcut overrides affect displayed menus; field focus is distinct from Vim. | Improve fuzzy ranking, recent items, path disambiguation and context-aware command availability. |
| File tree | Create/rename/move/delete and decorations | Partial. Virtualized rows, reveal ancestors, installed icons, file opening/dragging and new document. | Existing-item rename/move/delete/new-folder workflows were not found. Add keyboard/context actions and synchronize open-file identities. |
| Tabs and navigation | Rich pane/tab navigation | Partial. Reorder, dirty marker, close protection and utility tabs work. | Existing chevrons switch adjacent tabs, not cursor-location history. Add real back/forward history, MRU, overflow list and duplicate-name disambiguation. |
| Pane layout | Multiple nested splits and configurable docks | Partial. Two panes, four directions, divider resizing, shared documents and per-panel widths. | Pane trees/dock placement and more than two working files need a new layout model. Preserve current two-pane quality while adding keyboard focus first. |
| Projects/session | Multiple projects and multi-root on audited main | Partial. A real local project/workspace and project picker. | No comparable multi-root or complete editor-session/crash restoration was found. Recovery is much more urgent than multi-project parity. |
| Settings/keymaps | Large settings set, context/chord bindings | Working subset. Separate native child window, search, atomic persistence, System appearance, fonts/themes/icons and JSON overrides. | Changes to JSON load on restart; single-stroke workspace keymap, bounded entries, no contexts/chords/visual editor. Add live reload and diagnostics before a larger settings catalog. |
| Markdown/images | Rich previews and image workflows | Partial. Linked Markdown source, local images/links, cached layout/image reuse and native first-frame image viewing. | Markdown subset, synchronous parse/layout, no full block virtualization; no remote images or image zoom/editing. Move parse work first, optional rendering features later. |

### Tools, agents and platform integration

Upstream sources and their limitations are collected in the [Zed survey](zed-current-capabilities-2026-11-06.md). Local evidence: [agent guide][agent-guide], [agent service][agent-service], [extension guide][extensions-guide], [native runtime][native-runtime].

| Feature | Zed | Zircon: what is done properly | Gap and recommendation |
| --- | --- | --- | --- |
| Terminal and tasks | Integrated terminals, tasks/runnables and rerun | Missing | Essential for a daily coding editor. Start with terminal cwd, output, interrupt, resize, exit status and clickable paths, then task configuration. |
| Debugger/REPL | DAP client and Jupyter-kernel REPL | Missing | Debugger is next-stage IDE scope; REPL is language/audience dependent. Neither should precede save/input/navigation reliability. |
| Native agent workspace | Native/external ACP agents and CLI terminal threads | Working partial. Codex app-server and ACP integration, streaming/tool state, permission UI, cancellation, attachments of text and persisted conversations. | No comparable worktree isolation/delegation UI, image context, full ACP client RPC, all elicitation schemas or selectable rendered chat text. |
| AI editing/prediction | Agent edits, inline assistant, separate edit prediction and commit generation | External-agent editing is available through provider tools and post-turn clean-file reload | No first-class inline transformation/review or predictive edit integration. Improve review/undo/context before adding more model providers. |
| Extension ecosystem | Language, theme, icons, snippets, debugger/MCP contributions | Working interoperability subset. Official catalog, installs/updates/rollback, theme/icons, WASM LSP adapters and real grammar execution. | Seeing an extension in the catalog is not compatibility certification. Unsupported debugger/MCP/snippet contributions and API imports need clear labels. |
| Remote/container development | SSH/WSL/dev containers with documented limits | Missing | Important for server-oriented users; defer until local file/process boundaries are reliable. |
| Collaboration | Shared editing/cursors, calls, channels, project sharing | Missing | Large separate product commitment. Low priority for a local-editor milestone. |
| Accessibility | AccessKit infrastructure; application path experimental and default-disabled in audited main | Missing complete native accessibility metadata/text semantics | Must establish keyboard access, roles/names, focus and editable text support. Do not use Zed's incomplete support as a reason to defer this indefinitely. |
| OS integration | Desktop menus, file opening and supported desktop platforms | macOS native windows, Metal, traffic lights, clipboard and child settings | No native menus/dialogs or OS-file-drop parity; no Linux/Windows native adapter. Portable compilation is not Linux desktop support. |
| Distribution | Supported release channels and installers | Local signed test app/ZIP with extension host | Not notarized production distribution. Establish signing/notarization, updates/rollback, logs and support diagnostics before public release. |

### Operational limits users will encounter

These are independent subsystem policies in current source, not one unified large-file mode. A file can open successfully and still exceed search, grammar or LSP limits.

| Area | Current limit/policy | User-visible implication |
| --- | --- | --- |
| Workspace file I/O | 64 MiB open/save limit | Editing storage can grow separately; do not let an oversized paste lead to a surprising inability to save without warning. |
| Logical line display | 64 KiB | Long generated/minified lines show a display notice. |
| Buffer regex search | 8 MiB source, 20,000 matches, 8 MiB aggregate expanded replacement output | Truncation/error must disable unsafe replace-all and explain the limit. |
| Project search | Default 8 MiB/source, 128 MiB searched total, 10,000 matches, 20,000 sources, 64 KiB query | Missing results may mean a budget was reached, not that the text is absent. |
| File index | 20,000 files, depth 32, fixed excluded names | Need a persistent coverage indicator and configurable scope. |
| Grammar/folding | Full-document grammar/fold work stops above 8 MiB | Opening a large file does not imply normal structure features. |
| LSP framing | 8 MiB JSON message, 16 MiB outgoing queued bytes | Full-text changes can exceed the message limit before the raw file reaches 8 MiB because JSON escapes add bytes. Negotiate sync and expose errors. |
| LSP incoming | 1,024 queued messages and 16 MiB accounted arena capacity | The client bounds queued output; pressure needs a visible failure/recovery policy. |
| Undo history | Default 512 document history entries, separate editor selection history bound | Entry counts do not bound retained bytes after large replacements. |
| Git commands | 30 seconds per command; 64 MiB stdout and 1 MiB stderr | Large diffs/slow credentials/remotes can fail; a sequence of commands has no equivalent single 30-second job deadline. |
| Extension worker commands | 120 seconds, 64 MiB stdout, 64 KiB stderr | Persistent progress and actionable timeout errors are necessary. |
| Agent transcript view | Most recent 256 KiB rendered, 80 ms stream coalescing | Full JSON transcript exists separately; rendered history is intentionally bounded. |

Search matching also differs between subsystems. Buffer regex uses the Rust worker's Unicode regex engine; project literal search's insensitive matching uses ASCII folding. A shared-looking toggle should not imply identical Unicode case/word behavior without unifying those semantics.

## Text updates: what works and what must improve

### Existing flow

An input event reaches the selected editor, which resolves commands and edits. `Document.apply` validates a captured revision, constructs a candidate rope/history entry, then publishes the new content and a `Change` mapping. The other pane maps its selections through that change. Editor preparation updates native surrounding text; Markdown, search and language services observe the new revision. Async completions are checked before installation.

This is the right separation. In particular, an unchanged document state after undo can be recognized as saved even though its revision increased. Late completion results cannot simply write into whichever file happens to be active. Hunk expansion and wrapping do not mutate source bytes. These are concrete strengths.

### Expensive work still follows an edit

1. The native event handler requests `.refresh` from Git on changes/undo. The Git job rediscovers the repository, queries status, queries up to 100 history entries, reads an index baseline and diffs the captured buffer. Busy refresh requests coalesce, but repository metadata and local text diffs still share one lane.
2. `Client.didChange` copies the full document and JSON-serializes it before enqueueing. Moving the writer to another thread does not remove this caller-side copy/serialization. The initialization parser records completion support but does not negotiate and retain the server's `textDocumentSync` mode.
3. Grammar highlighting waits for 80 ms of inactivity, then copies the full visible document and launches a worker process which reparses it. At most one request per visible document is in flight; obsolete responses are rejected. That limits concurrent work but is not incremental parsing.
4. `Canvas.prepaint` calls folding `ensure`. On a new revision it flattens/scans documents up to 8 MiB even when wrap is off. Wrapping can reuse shaping for unchanged lines, but its index rebuild still visits all source lines and copies rows.
5. Markdown refresh and invalidated layout remain synchronous. Buffer regex search also copies/serializes full text on the caller before worker execution.

These are source-derived cost mechanisms. They do not establish current p95 latency or say which mechanism dominates a given project.

### Required update contracts

| Update | Required behavior | Why it matters |
| --- | --- | --- |
| Local edit | Commit bytes/selection/history immediately; enqueue derived work | Typing must not wait for Git, parsing or language-server output. |
| Ordinary second-pane edit | Map source positions through the same committed change | Different panes must not edit stale offsets. |
| Undo/redo/external reload | Deliberately restore/map each view's selection, scroll and folded ranges | A reset flag and clamping alone are not a full navigation policy. Test jumps and folds, especially when line counts shrink. |
| LSP update | Honor None/Full/Incremental sync and negotiated position encoding; preserve ordered versions | Servers that advertise incremental sync should receive valid range changes. Skipping versions is only safe when composing correct changes or sending a permitted full update. |
| Diagnostics | Keep session/URI/version checks; distinguish current from potentially stale unversioned output | If a server omits version, comparing against the client's current sent version cannot identify the version it actually analyzed. |
| Clean disk edit | Auto-reload with stable view positions and emit the ordinary document-change path | Formatter, terminal or agent changes should appear without switching tabs. |
| Dirty disk edit | Preserve local bytes and offer compare/reload/overwrite/save-as | User edits must survive external updates. |
| File rename/delete | Update identities, titles, LSP URI, search/index and recovery metadata | Renaming a file must not strand an open document. |
| Parser/search result | Install only for matching document/configuration/request generation | Revision checks alone do not cover grammar/theme/provider replacement. |
| Font/theme change | Invalidate shaping/wrapping/hit geometry when metrics change; repaint-only where possible | Cursor, selection and text must use the same geometry. |

Recommended implementation sequence: define one document-change event carrying mappings and origin; maintain bounded per-document change batches; negotiate LSP sync; introduce persistent parser workers; move full scans outside paint; then add syntax-backed folds and incremental display indices. Preserve the current ownership/lifetime checks rather than replacing them with loosely shared mutable state.

## Git updates: correctness and scheduling

### Three states must remain visible

Git has HEAD, the index, and files on disk. Zircon also has unsaved buffer text. A gutter comparing index to buffer answers a different question from a Git file list comparing index to disk. The existing code makes that distinction internally. The UI must teach it at the point of staging.

For example, save `value = 2`, edit the buffer to `value = 3` without saving, then stage. Ordinary `git add` stages `2`. The gutter may still show `3` versus the index. That is valid, but a user should see "Unsaved changes are not included" and have an explicit save-and-stage action.

A combined HEAD-to-worktree comparison also has a subtle limit. If HEAD contains `1`, the index contains `2`, and disk returns to `1`, the combined net patch is empty while the index still holds a change. Never use combined patch emptiness to imply that there is nothing staged. Preserve index/worktree badges and separate inspection modes.

### Current strengths

Git commands run as entity-owned jobs; results own bytes and carry generations. Gutter/blame results require matching document revision. Repository commands pass paths as arguments rather than synthesizing shell text. The diff algorithm trims equal prefixes/suffixes and caps its LCS table at two million cells; larger ambiguous blocks become a coarse changed range. Dirty buffers block own branch/pull/stash worktree operations, and completion rechecks before reloading clean files.

Those are useful correctness and resource choices. The coarse-diff fallback is deliberate degradation, not the same thing as precise hunks for all sizes.

### Required redesign

- Separate repository metadata from per-document buffer diffs. Refresh history when HEAD changes or history is requested, rather than on every typing refresh. Cache baselines by repository/index identity.
- Watch worktree paths and Git metadata. Include index, HEAD, refs and common Git directory/worktree metadata. Coalesce bursts and recover after dropped events. Ignore the editor's own atomic-save temporary files.
- Give snapshots a repository generation as well as a document revision. External `git add` can change the index without changing the buffer. Rejecting old buffer revisions alone does not solve that.
- Use a mutation queue for stage/commit/checkout/stash and a separate latest-result lane for gutters/blame. Currently one `git.busy` state means a network command can hold up unrelated UI results. Never run concurrent index writers just to improve responsiveness.
- Make process cancellation real. The current runner caps stdout at 64 MiB, stderr at 1 MiB, and each command at 30 seconds. Cancellation checks surround the job; they do not interrupt an in-flight Git command. A multi-command job can take longer than one timeout. Support child/process-group termination and report whether the mutation completed before refreshing state.
- Show stale/pending/error states instead of quietly leaving old rows. Keep previous readable data during refresh, but stop generation-stale actions from operating on replaced rows.

Recommended first Git acceptance scenario: external add, external checkout, own stage, own stash, and typing during a slow fetch must all leave the visible status/index/buffer state correct, without repeatedly querying commit history. Hunk staging comes after those state boundaries are reliable.

## Must-have priorities

These priorities assume the product is a local coding editor for everyday use. They are recommendations, not a request to implement every Zed feature immediately.

| Priority | Deliverable | Done means |
| --- | --- | --- |
| P0 | Native input reliability | Resolve the reproduced dispatch failure; both foreground and fallback routes pass. Real IME composition and shortcuts work in editor, split, search, palette and settings. |
| P0 | Crash recovery and safe disk changes | Dirty/untitled buffers survive forced termination; reopening restores bytes and a useful session. External changes preserve unsaved edits and offer explicit resolution. |
| P0 | Grapheme-safe editing | Left/right/backspace/delete/selection do not split combining characters, flags or joined emoji. UTF-16 conversions and source offsets remain valid. |
| P0 | Automatic file/Git synchronization | External tool writes, Git changes, renames and deletes update the workspace; event storms do not overwrite dirty buffers or freeze typing. |
| P0 | Keep expensive work out of input/paint | Establish instrumentation, separate Git metadata, honor LSP sync and move folding/Markdown scans. Show limits rather than silently omitting coverage. |
| P1 | Language navigation and formatting | Definition/reference/hover/signature, real back/forward history, format, rename and code actions work with version-checked edits. |
| P1 | Complete everyday search | Project regex and include/exclude paths, ignore rules, replacement preview and explicit incomplete-result states. |
| P1 | File management and navigation | New folder, rename/move/delete, duplicate-name disambiguation, overflow/MRU, recent projects and useful pane focus shortcuts. |
| P1 | Terminal/tasks | Build/test inside the workspace, interrupt reliably, inspect exit status and jump from output to files. |
| P1 | Git completion | Hunk stage/unstage, conflict choices, file history, progress and cancellation. Saved-versus-unsaved staging is clear. |
| P1 | Keyboard/accessibility foundation | Every primary workflow is keyboard-operable with visible focus; controls expose roles/names and text editing is accessible. Track screen-reader acceptance explicitly. |
| P2 | Broader IDE/workspace | Arbitrary pane trees, DAP debugger, richer snippets, semantic tokens/inlay hints, remote SSH, worktree isolation and richer agent review. |
| P3 | Product expansion | Multiplayer/calls, REPL, extensive legacy encodings, complex agent orchestration and image editing, unless a chosen audience requires them sooner. |

Recovery and correctness should be release gates even if some P1 conveniences ship earlier. Scheduling is not a reason to hold fixes for the missing terminal until a fully generalized pane framework exists.

## UI changes that matter

The fresh captures show coherent title/tab/editor/status separation, restrained Git fills, real file icons and a useful inline find bar. Keep that direction. The must-have changes are mostly missing feedback and navigation affordances.

| UI change | Priority and reason | Acceptance condition |
| --- | --- | --- |
| Persistent operation/error area | P0. The status bar currently carries many unrelated messages. A long Git/LSP operation needs a visible identity and outcome. | Status remains compact; details open in a log/notification view; actionable errors survive subsequent typing; cancellation state is accurate. |
| External-change and recovery UI | P0. Silent stale text or ambiguous overwrite is worse than a cosmetic defect. | Clean reload is quiet; dirty conflict offers compare/reload/overwrite/save-as; restored unsaved buffers are clearly marked. |
| Visible focus and keyboard paths | P0/P1. Tooltips alone do not make controls usable. | Tab/Shift-Tab, arrows, Enter/Escape and focus return work across popovers, panels, two panes and agent permissions. |
| Completion popup with useful details | P1. Current list is functional but sparse. | Type/kind/detail/documentation are readable; selected item is unambiguous; filter/ranking and keyboard navigation work; popup never covers necessary input at edges. |
| Diagnostics and language status | P1. Bottom messages alone are insufficient for fixing code. | Underlines/gutter signs, counts, Problems list, next/previous diagnostic and server starting/ready/error indicators. |
| Real navigation history | P1. Current chevrons mean previous/next tab, which looks similar to location navigation. | History records source jumps and returns to prior file/caret/scroll; UI labels distinguish tab switching. |
| Tab overflow and duplicate filenames | P1. Capacity-based tab hiding makes large sessions harder to navigate. | Overflow list/MRU, path suffixes/tooltips, consistent close/dirty targets and keyboard discovery. |
| Project tree actions | P1. Opening files is not enough to manage a project. | Context/keyboard actions create folders, rename/move/delete, reveal in Finder and copy path; Git/diagnostic decorations remain distinguishable. |
| Search scope controls | P1. Buffer and project search have different capabilities today. | Regex/case/word/path controls appear where supported; incomplete results explain excluded bytes/files; replacement is previewable. |
| Git baseline/staging clarity | P1. Combined review, index and unsaved text are distinct. | Visible comparison selector; per-file and per-hunk staging states; unsaved warning; empty combined diff does not hide staged state. |
| Conflict resolution | P1. A conflicts group needs an actionable destination. | Show conflicting regions, ours/theirs/both/manual choices, unresolved count and explicit stage-as-resolved action. |
| Bottom dock for terminal/output/problems | P1. These workflows need stable space while source remains visible. | Resize/show/hide and focus shortcuts; no fake buttons for unavailable tools. |
| Better pickers | P1. Current substring filtering is a useful start. | Fuzzy ranked results, matching highlights, path disambiguation, recency and consistent Enter/Escape behavior. |
| Live settings/keymap feedback | P1/P2. Restart-only JSON changes are easy to misread. | Save reloads valid changes; invalid entries get locations/reasons; effective bindings and conflicts are visible. Chords/contexts follow. |
| More expressive panes | P2. Two panes are a clear hard limit. | Directional preview, reliable focus/close and layout persistence before arbitrary nesting expands the UI. |
| Typography and scale acceptance | P1 verification. Visual quality depends on shaping and contrast more than extra decoration. | Inspect Retina/ordinary-density displays, 100/125/150/200% scale, light/dark themes, CJK/combining glyphs, narrow windows and long labels. Color emoji remains a declared rendering gap. |
| Agent transcript selection/review | P1 if agent mode is central. Copy-last/open-JSON is a workaround. | Select/copy any rendered response; attach context visibly; inspect changed files and retain approval choices during streaming. |

## Performance: likely risks and how to prove them

### Existing mechanisms worth keeping

The editor paints visible rows; project and catalog lists create visible rows; font choices are virtualized. Source snapshots share persistent storage. CoreText layouts, glyphs and image textures are cached. Markdown reuses decoded images and prepared layouts across scrolling. The event loop can sleep to deadlines and wake for owned external inboxes; caret updates use deadlines. Frame publication is transactional, and GPU buffer/resource leases protect in-flight work.

However, `Window.draw` rebuilds the root tree, calculates layout and paints a new scene whenever a window is dirty. Dependency invalidation does not imply subtree rendering reuse. A smooth short file therefore cannot prove that a caret blink in a large workspace is cheap.

### Investigate in this order

| Candidate cost | Evidence | First change to evaluate | Needed measurement |
| --- | --- | --- | --- |
| Git work following edits | `actions.editorInput` and Git `perform` query status/history and buffer diff | Separate buffer diff baseline/cache from metadata; coalesce local edits | Child commands per second, queue delay, gutter freshness and typing p95/p99 during local/network Git operations |
| Full-document LSP sync | `Client.didChange` copies and JSON-serializes full text | Negotiate sync; send versioned changed ranges; bound/coalesce queued updates | UI serialization time, bytes per edit, queue depth and server completion/diagnostic latency |
| Parser process startup/full parse | `pollSyntax` starts `highlight` worker per eligible revision | Persistent parser per grammar/document, incremental changes | Startup/parse/copy times, CPU and result delay during sustained typing |
| Folding scan in prepaint | `Canvas.prepaint` invokes revision-invalidated flatten/scan | Background or incremental ranges with generation checks | UI prepaint duration by file size, including wrap disabled |
| Wrap index copying | `Cache.ensure` iterates source lines even with reused shaping | Update changed line/row ranges in a cumulative index | Time/allocations for edit at start/middle/end and width/font resize |
| Full lexical rescan in some paths | `Editor.synchronize` clears then refreshes from row 0; local edits also have a narrower convergence path | Preserve valid prefixes and instrument causes of reset | Scanned lines per edit, especially shared-pane edits and undo |
| Sync I/O and hashing | Workspace read/save/stamp/clean reload use synchronous I/O | Snapshot-based async read/write/hash, serialize publications | Main-thread blocked time, save response and conflict correctness on slow storage |
| Markdown and agent transcript rebuilds | Source/stream refresh replaces text, synchronous parse/layout, 80 ms stream coalescing | Background block parse/layout and append-aware rendering | Input/scroll p95, stream update CPU and allocation growth |
| Native input snapshot size | Canvas includes entire selected span plus surrounding context | Separate selected-range metadata from bounded native surrounding-text supply | Select-all frame time/RSS on large files without breaking IME APIs |
| Whole-window rebuild and text batches | `Window.draw`, renderer run/glyph extraction and colored spans | Profile before changing frame/layout or glyph batching | Time in tree/layout/prepaint/shaping/GPU upload; cache hits and present delay |
| Process and history memory | Rope history, selections, active frames, host/LSP/agent processes and images | Measure ownership lifetimes and byte-aware budgets | Whole process tree RSS, GPU allocations and retained memory after closing tabs/projects |

Cache budgets are not process memory ceilings. Active arenas, in-flight GPU resources, document histories and child processes all count separately. The current history entry bound is not a fixed byte bound. Report idle and peak process-tree memory with a defined workload instead of adding cache limits together.

### Benchmark plan

Use the existing [benchmark method](../benchmarks/method.md) as a starting point. Build Zircon in release mode, record exact Zed binary version/build, hardware, OS, display/refresh rate, fonts, extension versions and language-server versions. Give both editors equivalent features and datasets. Measure with services disabled as a diagnostic variant, not as the headline comparison against a fully enabled competitor.

| Workload | Required cases | Record |
| --- | --- | --- |
| Typing and deletion | Small file, 1/8/32 MiB source; start/middle/end; undo/redo; wrap/fold on/off | Event-to-present p50/p95/p99, UI blocked spans, allocations per edit; not only `Document.apply` time |
| Unicode/IME | Combining accents, CJK, family/flag/skin-tone emoji; composition and cancellation | Correct bytes/history/selection plus latency; correctness is a gate, not an averaged speed score |
| Long lines | Generated/minified files, including lines over current 64 KiB limit | Openability, explicit fallback, selection/scroll behavior and memory |
| Large workspace | 1k/20k/100k files, ignored/generated trees, many small files | Startup to editable, finder/search coverage, indexing CPU, incomplete-result reporting |
| Search | Literal/regex, many matches, unsaved buffers, repeated changed queries | Time to first/final usable result, obsolete-result rejection, CPU and process startup |
| Git | Clean and many-changes repos, partially staged files, external changes, large diff, slow remote | Freshness, command counts, queue length, cancellation outcome and typing while work runs |
| Save/reload | Ordinary/slow storage, competing writer, renamed/deleted file, branch switch | UI block time, atomicity, dirty-buffer protection and recovery |
| Language services | Large TypeScript/Rust/Zig files, rapid edits, several open documents | Bytes/versions sent, request latency, stale-result safety and process-tree memory |
| Scroll/render | Dense syntax, selections, expanded hunks, split panes, image/Markdown/streaming transcript | Missed frames and CPU/GPU time, cache misses, text correctness and energy |
| Long session | Hours of tab/project/theme/extension cycles, cancel/reconnect | Steady-state/peak memory, handles/threads/processes and release after closure |

Suggested initial engineering budgets are a foreground main-thread edit path below 4 ms at p95 on the chosen reference machine and local event-to-visible p95 within two display refresh intervals. These are proposed targets, not measured results or universal promises. A 120 Hz frame interval is about 8.3 ms and 60 Hz is about 16.7 ms; input-to-present includes scheduling beyond editor mutation. Set watcher freshness and remote-operation budgets separately and publish tails/outliers, not just averages.

Do not use build time, test-suite duration, PNG generation time or an isolated rope benchmark as evidence that typing beats Zed. Keep failures, truncation and incomplete indexing visible in any performance report.

## Delivery sequence and acceptance gates

1. **Establish trust in files and input.** Reproduce/fix native dispatch, add real foreground/IME acceptance, grapheme-safe operations, external watchers, recovery/session restoration and conflict UI. A forced-kill/external-edit journey must recover bytes exactly.
2. **Make updates cheap and observable.** Separate Git metadata and buffer diff lanes; negotiate LSP sync; persistent parsing; folding/Markdown outside paint; instrumentation and visible operation status. Compare the same representative workloads before/after each targeted change.
3. **Complete the coding loop.** Definition/references/hover/history, formatting/rename/actions, full project search, file management, terminal/tasks and diagnostic UI. A developer should navigate, edit, build, fix an error and commit without leaving Zircon for routine work.
4. **Complete integrated review.** Hunk staging, conflict handling, file history, agent output selection and explicit edit review. Test partial-index and unsaved-buffer cases, not only whole-file staging.
5. **Expand deliberately.** Nested panes, debugger, remote development and worktree-isolated agent sessions. Revisit multiplayer/REPL only against the chosen audience.

The existing CI workflow runs `zig build check` on Ubuntu and macOS. It does not establish current native foreground/IME/VoiceOver acceptance, comparative performance, or notarized packaging. Add a macOS native lane with uncached execution semantics, Rust worker tests/clippy, a packaged-app smoke test and reproducible performance smoke workloads. Explicitly separate environment-unavailable native checks from a passed fallback route. Preserve the raw test failure until a fresh run proves it fixed.

## Local evidence index

These links identify the implementation examined at the Zircon commit named above. Future edits can change the linked files; use that commit for historical comparison.

[text]: ../../packages/zircon_text/src/rope.zig
[snapshot]: ../../packages/zircon_text/src/snapshot.zig
[document]: ../../packages/zircon_text/src/document.zig
[editor]: ../../packages/zircon_editor/src/editor.zig
[wrap]: ../../packages/zircon_editor/src/wrap.zig
[folding]: ../../packages/zircon_editor/src/folding.zig
[persistence]: ../../packages/zircon_workspace/src/persistence.zig
[language-service]: ../../apps/zircon/src/services/language.zig
[lsp]: ../../packages/zircon_language/src/client.zig
[extensions-guide]: ../zed-extensions.md
[git-service]: ../../apps/zircon/src/services/git.zig
[git-root]: ../../packages/zircon_git/src/root.zig
[git-diff]: ../../packages/zircon_git/src/diff.zig
[git-process]: ../../packages/zircon_git/src/process.zig
[guide]: ../editor-guide.md
[buffer-find]: ../../apps/zircon/src/services/buffer_find.zig
[project-search]: ../../apps/zircon/src/services/search.zig
[search-engine]: ../../packages/zircon_search/src/root.zig
[project-index]: ../../apps/zircon/src/project_index.zig
[project-ui]: ../../apps/zircon/src/views/project.zig
[chrome]: ../../apps/zircon/src/views/chrome.zig
[settings]: ../../apps/zircon/src/settings/store.zig
[agent-guide]: ../agent-mode.md
[agent-service]: ../../apps/zircon/src/services/agents.zig
[native-runtime]: ../../packages/zircon_ui/src/platform/macos/window.zig

Additional sources: [editor canvas](../../packages/zircon_editor/src/canvas.zig), [edit propagation](../../apps/zircon/src/actions.zig), [frame publication](../../packages/zircon_ui/src/app/window.zig), [event loop](../../packages/zircon_ui/src/app/app.zig), [shaping cache](../../packages/zircon_ui/src/text/shaping.zig), [Metal renderer](../../packages/zircon_ui/src/graphics/backends/metal.zig), [native failing assertion](../../packages/zircon_ui/src/platform/macos/window_test.zig), [application journeys](../../apps/zircon/tests/native_journey.zig), [feature journeys](../../apps/zircon/tests/experience_tests.zig), [CI](../../.github/workflows/framework.yml), [search limits](../../packages/zircon_search/src/types.zig), [regex worker](../../tools/zed-extension-host/src/search.rs), [LSP framing](../../packages/zircon_language/src/framing.zig), [extension process bounds](../../apps/zircon/src/services/extension_host.zig), [history](../../packages/zircon_text/src/history.zig).
