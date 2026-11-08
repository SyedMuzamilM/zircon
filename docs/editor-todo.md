# Editor checklist

Updated 2026-11-07. Use the [roadmap](editor-roadmap.md) for sequence, ownership rules and milestone gates. Findings originate in the [Zed comparison](research/zircon-vs-zed-audit-2026-11-06.md) and [upstream survey](research/zed-current-capabilities-2026-11-06.md).

Existing functionality is described in the audit and subsequent progress records. These tasks address remaining gaps. Default owner is unclaimed; delivered EXT work belongs to its original implementation, with follow-up acceptance recorded below. Dependencies are task IDs, not claims that predecessors are already done. Dependencies labeled "integration" permit separate package work earlier, but require the predecessor before application delivery.

Status values: open, active, external active, verify, done. Record status and owner when claiming a task. A checked box requires acceptance evidence. The first completed batch is documented in the [November 7 progress record](progress/2026-11-07-baseline.md).

## Active terminal and UI work

Original owner for EXT-01..08: <t3-thread://v2/b79b85d5-1375-4bbb-b783-8d130943f509/7afede22-0b3c-411f-8a04-0d7929d6e6cd>. Its implementation runs are complete; changes remain uncommitted in this checkout. The November 7 batch inspected the delivered source and passed 55 fresh native application journeys. EXT-01 and EXT-05 are accepted below; the other EXT items are in verify status for their remaining acceptance scope, not missing implementations. Preserve existing code and test only the remaining conditions before claiming completion.

- [x] **EXT-01: Consistent active-line background across wrapped rows.**
  Scope: editor canvas and rendering regression. Done: all visual rows of the focused source line have the intended background; neighboring lines and inactive panes remain correct. Preserve the in-flight fix and check its actual result.
  Evidence: fresh editor suite, 41 checks, including wrapped-row background; native application checks retain focused-pane highlighting. Follow-up fixes repeat source indentation on continuation rows and preserve inline Git backgrounds through the gutter. See [wrapping follow-up](progress/2026-11-07-wrapping-performance.md).

- [ ] **EXT-02: Compact status controls and sidebar toggles.**
  Scope: status-bar icons, selected color without selected background, requested separator/order, remove separate Git-history shortcut. Done: controls toggle the right panel, fit narrow windows, retain hover/help/focus and do not hide errors.

- [ ] **EXT-03: Language-server status and language picker.**
  Scope: selected server/state/error information; Vim mode, row/column and change-language picker. Done: UI reflects the active pane/document and actual service state; selection changes effective language support rather than just its label.

- [ ] **EXT-04: Terminal sessions with tabs and bottom/right placement.**
  Scope: terminal implementation, native input, scrollback and dock placement. Done: create/switch/close multiple sessions, resize, Unicode/paste, shell cwd, Ctrl-C, process exit and cleanup work; changing placement preserves sessions; focus returns to source. Agree its process/task interface before DEV-01.
  Verify: real PTY output, Ctrl-C/recovery, shell exit, source isolation, tabs/hide/docking and persisted placement pass. Broader Unicode/paste/resize/focus and process-cleanup acceptance remains; full terminal-protocol emulation is not established.

- [x] **EXT-05: Independent pane tab groups and directional drops.**
  Scope: pane/tab models and source-file drops left/right/top/bottom. Done: groups have independent active tabs; shared documents keep correct bytes/history and separate selections; move/close/resize/cancel-drop preserve dirty files and focus. Record whether arbitrary nesting is included or remains WORK-01.
  Evidence: current native journeys cover four-edge drops, group-specific source/tool tabs, resizing, shared documents and dirty secondary close/primary promotion. Arbitrary nesting remains WORK-01; delivered scope is two groups.

- [ ] **EXT-06: Branch/stash and project/recent-project menus.**
  Scope: menus from branch/project controls, branch creation, stash access, recent projects. Done: operate on real current project/repository identities; unavailable operations explain why; recent selection opens the right path. Preserve existing dirty-buffer guards.
  Progress: `5700514` fixes stable segmented branch/stash tabs, search focus and native resize feedback. Joined Stage All/Publish controls and rounded real Git counts are verified in [Git UI evidence](reviews/editor-program-2026-11-07/git-ui-evidence/README.md). Remaining acceptance stays open.
  Progress: `19c26f5` adds worker-built file/hunk projection, unified/split state, collapse offsets, file headers and toolbar commands. `diff-projection-evidence` passes the real temporary-repository model test. Source-backed editing and hunk staging remain WORK-02/GIT-05.

- [ ] **EXT-07: Agentic layout switching.**
  Scope: requested editor/agent workspace placement. Done: switch layouts without losing conversation, terminal sessions, document focus, tabs or drafts; persisted preferences match behavior.

- [ ] **EXT-08: Image view and clean tabs/file header.**
  Scope: requested image presentation, tab close hover and source-path/header controls. Done: image navigation/close preserve source context; duplicate/long names remain discoverable; controls fit light/dark and narrow layouts.

## M0: establish ownership and a reliable baseline

- [x] **BASE-01: Reconcile the active changes and assign integration ownership.**
  Depends: none. Scope: current diff, EXT entries, status/guide consistency and this checklist. Done: record delivered/remaining EXT scope and commit/evidence; reserve shared application files; correct stale "no soft wrap" status text; future tasks start from accepted behavior. Do not wait for the entire EXT batch to establish initial ownership.
  Evidence: November 7 progress record. Current batch owns native verification/tests/CI and documentation; preserves the completed terminal/UI diff. Status now reflects terminal, pane groups, wrapping/folding and image controls. Further integration claims must retain this baseline.

- [x] **BASE-02: Make uncached native verification reproducible.**
  Depends: BASE-01 ownership check. Scope: build/test tooling, native input logs and CI. Done: one documented command really executes the relevant native suites sequentially; reports foreground/fallback modes, skips and failures separately; retains the existing `TextDispatchFailed` until resolved. Cached compilation remains allowed.
  Evidence: `test-native-fresh`, always-executed native run steps, separate route records, native CI/artifact job and repeated fresh runs. See [commands](native-verification.md) and November 7 evidence. Remote CI execution is not claimed.

- [x] **BASE-03: Capture repeatable editing and update baselines.**
  Depends: BASE-01. Scope: existing benchmark tooling plus edit/frame/parse/Git/LSP counters. Done: named release builds/datasets record latency tails, blocked UI time, bytes/commands/parse starts and process-tree memory. Capture correct feature coverage and partial results; do not report build/test duration as typing speed.
  Evidence: [current complete baseline](benchmarks/editor-2026-11-07-lifecycle-current-git/README.md), all 40 attempts passed, five runs per configuration and 800 validated inputs. A live process capture traced grammar timeouts to pipe writers inherited by the Python LSP process. The Darwin spawn-isolation fix and deterministic handle regression are in `0b73351`. The earlier [34/40 batch](benchmarks/editor-2026-11-07/README.md) is retained; its two unknown-counter failures did not recur and are not retrospectively assigned a cause. This closes the controlled local baseline, not real-server compute, cold startup, long-session or physical key-to-scanout acceptance.

- [ ] **BASE-04: Shared visible operation/error state.**
  Depends: BASE-01; EXT-02/03 for UI integration. Scope: operation models/services and status/details UI. Done: saves, Git, LSP, downloads, search and tasks expose active/completed/error state; errors survive typing; progress/cancel accurately describe real work without serializing unrelated jobs.

## M1: file safety, text and synchronization

- [x] **TEXT-01: Resolve the native key/text dispatch failure.**
  Depends: BASE-02. Scope: macOS window/input routing and failing standalone test. Done: isolate missing/duplicate/timing behavior, fix the proven cause, pass fresh standalone and application journeys under foreground and fallback routing. Do not weaken the assertion to hide a routing failure.
  Evidence: two-window experiment reproduced zero events on the named window after queued delivery followed a focus change. Surface checks now bind input to the actual target first responder; dedicated foreground-queue and changed-focus checks preserve coverage and exact counts. Five final fresh standalone runs and all 90 native/real-server checks passed. Production input is unchanged; historical failure counters were unavailable, and full IME acceptance remains TEXT-02.

- [ ] **TEXT-02: Validate foreground IME and keyboard layouts.**
  Depends: TEXT-01; EXT-04/05 for terminal/pane integration. Scope: marked-text selectors, key dispatch and field focus. Done: CJK composition/cancel/commit, dead keys, Option layouts, clipboard, Vim Insert/Normal transitions and fields preserve exact bytes/history. Record real OS acceptance separately from synthetic selector checks.

- [ ] **TEXT-03: Grapheme-safe movement, deletion and selection.**
  Depends: BASE-01. Scope: text boundaries, editor navigation, Vim/display mapping and inputs. Done: combining marks, flags, modifiers and joined emoji are indivisible where users expect characters; CRLF and UTF-16 surrogate handling remain correct; wrapped hit testing and multicursor edits agree.

- [ ] **TEXT-04: Snapshot-based async open/save/hash/reload.**
  Depends: TEXT-07 contract; BASE-04 for UI integration. Scope: workspace persistence and owned jobs. Done: slow file I/O does not block input; atomic save/permissions/conflict policy survive; a save completion marks only its captured content saved; later edits remain dirty; closing/canceling cannot publish into another document. Document publication/cancellation limits.

- [x] **TEXT-05: Durable recovery and session restoration.**
  Depends: BASE-01; EXT-05 accepted pane model for layout integration. Scope: workspace recovery storage and session metadata. Done: forced termination restores dirty/untitled bytes, saved-file identities, useful selections/layout and recent project context; writes are atomic/versioned; corrupt records are recoverable; explicit discard removes the right backup. Account for recovery checkpoint interval and avoid treating backup as a disk save.
  Evidence: `8ea2d7e` delivers the storage format. [Application integration](progress/2026-11-07-recovery-integration.md) now wires startup/project windows, asynchronous checkpoints, restored primary selections/panes/language overrides, persistent error/last-checkpoint feedback and serialized close/discard. [Native subprocess evidence](reviews/editor-program-2026-11-07/recovery-app-evidence/README.md) proves three SIGKILL/restart cases and two idle close/restart cases. Fourteen added application behaviors cover late edits at both close boundaries, independent abandoned sessions, corruption salvage, failed publication, teardown and sustained input. Full multicursor sets, undo history and power-loss durability are outside this delivered scope.

- [ ] **TEXT-06: Watch external file changes and resolve conflicts.**
  Depends: TEXT-07; BASE-04 for UI integration. Scope: filesystem event service, workspace/index and conflict UI. Done: external edit/atomic rename/delete/create updates clean files and tree; dirty text is preserved with compare/reload/overwrite/save-as; dropped-event rescan and own-save filtering work; bursts coalesce; LSP/search/preview/recovery receive resulting changes. Integrate async reads through TEXT-04 when available.

- [ ] **TEXT-07: One committed document-change path for every edit origin.**
  Depends: BASE-01; EXT-05 for pane integration. Scope: document/workspace events and application propagation. Done: local edits, undo/redo, reload, completion, formatting, agents and project edits carry document identity, revisions/content state, origin and mapping policy; views/search/LSP/preview/recovery receive ordered updates. Verify selections, scroll and collapsed ranges after reset/undo as well as ordinary edits.
  Progress: [initial shared event contract](progress/2026-11-07-document-events.md) is implemented. Workspace events transfer owned mappings without post-commit allocation. Shell retains bounded history and publishes typing, completion, search replacement, commands and explicit undo/redo resets, including Vim. Remaining consumers and edit origins are open.

- [ ] **TEXT-08: Encoding and line-ending policy.**
  Depends: TEXT-07; TEXT-04 for persistence integration. Scope: decoding metadata, save policy and encoding UI. Done: explicitly handle UTF-8 BOM and UTF-16, preserve chosen LF/CRLF behavior, reject unsupported/bad input visibly and prevent silent lossy conversion. Track broader legacy encodings under PLATFORM-03.

- [ ] **TEXT-09: Explicit large-file and long-line behavior.**
  Depends: BASE-03/04. Scope: shared limits/capability state across open/save, search, LSP, grammar, folds and rendering. Done: explain disabled/truncated features; oversized paste cannot surprise the user with unsavable content; generated long lines have a usable viewing strategy; limits are configurable only where correctness/resource bounds support it.

- [ ] **GIT-01: Separate buffer diffs from repository metadata refresh.**
  Depends: BASE-03; TEXT-07 for integration. Scope: Git service and editor change scheduling. Done: typing schedules latest-buffer diff work, not repeated history/status commands; baselines cache against repository/index identity; metadata refreshes for actual invalidations; command counts and gutter freshness are demonstrated.

- [ ] **GIT-02: Automatic repository/index updates with generation checks.**
  Depends: GIT-01, TEXT-06 event delivery. Scope: Git watches including common/worktree directories, HEAD/index/refs and status. Done: external add/reset/checkout/stash changes the right status/baseline even without buffer edits; dropped events recover; old jobs/actions cannot install or mutate replaced identities.

- [ ] **GIT-03: Mutation scheduling, real process cancellation and progress.**
  Depends: GIT-01, BASE-04; EXT-04 process-interface coordination. Scope: repository jobs/process runner. Done: serialize conflicting mutations, keep appropriate read/diff work responsive, interrupt child/process groups where supported, distinguish completed mutation from canceled waiting/result delivery, refresh actual state after cancellation/errors and expose credentials/timeouts. Avoid concurrent index writers.

- [ ] **GIT-04: Make saved/index/buffer comparisons explicit.**
  Depends: EXT-02/06, GIT-01. Scope: stage actions, comparison selector and file states. Done: unsaved bytes are clearly excluded from ordinary staging; explicit save-and-stage captures the intended revision; empty HEAD-to-worktree net patches cannot hide staged differences; all controls label their baseline.

## M2: language services and everyday coding

- [x] **UI-01: Compact typed UI composition with executable documentation.**
  Scope: `zircon_ui` constructors, callback payload inference, examples and application consumers. Done: eager tuples accept elements/results, modifiers propagate failures, button metadata avoids wrapper nesting, callbacks infer pointer-free payloads, and compiled examples stay synchronized with the public guide. [Design and verification](design/ui-syntax.md), [usage](zircon-ui-composition.md) and [acceptance logs](reviews/editor-program-2026-11-07/ui-composition-evidence/README.md) cover ownership, allocation failures, focus, large arrays and lexical migration. Shared copied-value validation closes error-union pointer escapes for handlers and entity results. This does not complete contextual keymaps, stock lists or native platform adapters.

- [ ] **LANG-01: Negotiate LSP synchronization and position encoding.**
  Depends: TEXT-07; BASE-03. Scope: language client and change batching. Done: honor None/Full/Incremental and supported encoding, preserve ordered valid versions, bound/coalesce output without losing edits; test a slow server, rapid changes, undo, reopen and Unicode. Measure copied/serialized bytes and queue pressure.
  Progress: [negotiated synchronization](progress/2026-11-07-lsp-incremental.md) honors None/Full/Incremental and UTF-16. Exact insertions, deletions, replacements and disjoint batches reconstruct server text; missing history and undo use ranged replacement. Queue-pressure retries preserve versions. Slow-server/coalescing acceptance and broader application integration remain open.

- [ ] **LANG-02: Persistent grammar worker lifecycle.**
  Delivered correction: `e08fdc5` isolates language-picker rebindings to the affected document, preserves unrelated clients/diagnostics, and rejects stale grammar/resolver epochs. `1f8f99e` locks shared resolver installation writes. Persistent parsing workers, bounded input cancellation and retry policy remain open.
  Depends: BASE-03; EXTAPI-01 for compatibility integration. Scope: extension host and syntax service. Done: retain grammar/process state across eligible edits, avoid per-request worker startup, bound memory and cancel/disable/restart safely; stamps include grammar/config/document generations. Keep fallback highlighting on failures.
  Follow-up evidence: the four BASE-03 grammar timeouts were traced to inherited stdin writer handles and fixed by Darwin child isolation in `0b73351`; the new matrix passed 40/40. Persistent workers, bounded input/cancellation, retry policy after failure and configuration epochs still require implementation under this ID.

- [ ] **LANG-03: Incremental parsing and language-backed folding.**
  Depends: LANG-02, TEXT-07. Scope: edit-to-parser mapping, injections and fold ranges; provide ranges/events consumed by PERF-01 display caches. Done: apply exact edits to retained parse trees; highlight/query changed regions; support validated Tree-sitter/LSP fold ranges where available; retain indentation fallback and remove full folding scans from prepaint.

- [ ] **LANG-04: Definition/reference/symbol navigation.**
  Depends: LANG-01; UX-02 for history integration. Scope: protocol requests, source locations, outline/project symbols and result views. Done: navigate/peek correct definitions, types/implementations and references supported by the server; open closed files; reject stale results and return to prior location. Deliver definitions first, then remaining methods under this ID with evidence per method.

- [ ] **LANG-05: Hover, signature help and useful completion details.**
  Depends: LANG-01; EXT-03 UI boundary. Scope: completion capability/trigger handling, hover/signature and popup. Done: actual server triggers, documentation, filtering/selection and cursor invalidation work; popups fit edges and keyboard focus; snippet insertion has placeholder navigation and one undo transaction before advertising snippets.

- [ ] **LANG-06: Safe workspace edits, rename and code actions.**
  Depends: LANG-01, TEXT-07, TEXT-06; TEXT-04 for async publication. Scope: shared project edit validation/publication and LSP operations. Done: preview affected files, validate open/closed-file revisions/stamps and resource operations, preserve dirty buffers, define cancellation/partial-disk-failure recovery and grouped undo. SEARCH-03 reuses this transaction policy.

- [ ] **LANG-07: Formatting and format-on-save.**
  Depends: LANG-01, TEXT-07; LANG-06 shared edit validation where applicable. Scope: formatter requests/external tools and settings. Done: explicit document/selection format is undoable; late results cannot overwrite typing; optional format-on-save has a declared save ordering and actionable timeout/error behavior. Preserve file encoding and line endings.

- [ ] **LANG-08: Diagnostics views and language-server lifecycle feedback.**
  Depends: LANG-01, BASE-04; EXT-03 UI integration. Scope: diagnostics, Problems view, squiggles/gutter/counts, server logs/restart. Done: navigate current diagnostics and related locations; distinguish unversioned/possibly stale output; handle server restart/failure, supported push/pull diagnostics, save/watch notifications and bounded output. Never present a client's current version as proof of an unversioned server result's analyzed revision.

- [ ] **LANG-09: Per-language editor configuration.**
  Depends: UX-03, EXT-03, EXTAPI-01. Scope: language identity, indent/comment/bracket/format/server configuration. Done: language selection changes effective configuration across services; project/global precedence and live reload are clear; invalid rules explain errors; more languages can supply behaviors without hard-coded application branches.

- [ ] **SEARCH-01: Shared ignore-aware, watched project index.**
  Depends: TEXT-06; BASE-04. Scope: file finder/search/tree indexing. Done: `.gitignore` and explicit includes/excludes have documented precedence; symlink/cycle policy is safe; incremental updates handle renames/deletes; coverage limits and errors stay visible; configurable exclusions replace guessed folder-name parity.

- [ ] **SEARCH-02: Project regex and search scope controls.**
  Depends: SEARCH-01. Scope: search engine/UI and shared query semantics. Done: regex/case/whole-word/path filters operate on disk plus unsaved/untitled buffers; Unicode semantics are documented; invalid patterns, limits and skipped files are visible; selection-only buffer search is supported; obsolete queries cannot replace current results.

- [ ] **SEARCH-03: Preview and apply project replacement.**
  Depends: SEARCH-02, LANG-06 shared transaction policy. Scope: replacement preview, multi-file edits and undo/publication. Done: preview exact captures and changed files; revalidate stamps/revisions; preserve unsaved edits; report partial filesystem failure and recover; disabling replace on incomplete results prevents accidental partial replacement.

- [ ] **SEARCH-04: Live/stale result refresh.**
  Depends: SEARCH-02, TEXT-07. Scope: result subscriptions/cancel/coalescing and navigation. Done: edits and file changes refresh the affected result sets or mark them stale; retain useful selection/scroll; canceled queries leave no orphan processes; per-query result coverage remains visible. Direct combined-excerpt editing is WORK-02.

- [ ] **UX-01: Complete file tree operations.**
  Depends: TEXT-06/07, SEARCH-01; EXT-06 menu integration. Scope: new folder, rename/move/delete, copy path, Finder reveal, Git/diagnostic decorations. Done: operate on current identities, preserve open dirty files, update LSP URI/recovery/index, expose keyboard/context actions and deliberate destructive confirmation. Use LANG-06 resource-edit policy where shared.

- [ ] **UX-02: Location history, MRU/tab overflow and fuzzy discovery.**
  Depends: EXT-05/06/08. Scope: navigation state, palette/file finder and tab groups. Done: real location back/forward restores caret/scroll; MRU and overflow find hidden tabs; duplicate names show paths; fuzzy ranking/match highlights/recency are consistent; command availability and effective shortcuts reflect focused context. Provide history interface early for LANG-04. Add the shared below-tab file breadcrumb/action toolbar from the November 7 reference, with active-pane path and real current-symbol data when available.

- [ ] **UX-03: Live settings and contextual keybindings.**
  Depends: EXT-02/03/05. Scope: settings reload/diagnostics, chords/contexts and keymap UI. Done: valid JSON applies live; invalid fields retain last valid effective values with locations; overrides/unbinding/chords/context precedence are visible; text fields, Vim and terminal keys route to the focused target. Preserve installed choices and configured light/dark theme pairs.

- [ ] **UX-04: Keyboard access and focus across primary workflows.**
  Depends: EXT-02..08 integration. Scope: controls/pickers/panels/editor/agent permissions. Done: Tab/Shift-Tab, arrows, Enter/Escape, pane/dock switching and focus return work with visible focus; no modal traps or accidental edits to the wrong target. Establish this during M1 and continue as new views land.

- [ ] **UX-05: Native accessibility semantics and acceptance.**
  Depends: UX-04; TEXT-02/03 for editable-text semantics. Scope: framework roles/names/actions/text selection and platform bridge. Done: actual accessibility tree and assistive-technology journeys cover editor, fields, menus, tree, dialogs, diagnostics and terminal; focus/selection/range queries match displayed text. Record supported scope and unresolved limitations explicitly.

- [ ] **UX-06: Native menus, dialogs and OS file opening/drops.**
  Depends: EXT-05/06, TEXT-06; UX-04. Scope: macOS application menu, open/save dialogs, file associations/drop routing. Done: actions target the active document/window, preserve dirty-close/conflict policies, accept OS files into the correct pane and remain keyboard-accessible.

- [ ] **UX-07: Text and control rendering across themes/scales.**
  Depends: EXT-01/02/08, TEXT-03; BASE-03 for performance checks. Scope: contrast, fallback glyphs, ligatures, emoji, scale/resize and geometry. Done: check ordinary-density/Retina displays, supported scales, CJK/combining text, long labels and light/dark; hit/caret/selection geometry agree; color emoji is implemented or its limitation remains explicit. Recheck font-family changes against wrapping/cache generations.

- [ ] **UX-08: Animated actionable extension recommendations.**
  Depends: EXT-02/03, BASE-04. Scope: bottom notification stack and persisted suppression. Done: opening a supported file without language support can recommend an available extension; Install, Don't Show Again, dismiss and Learn More act on the correct recommendation; installation progress/errors remain visible; entry/exit respects reduced motion. No automatic installation or external link opening. Reference and ordered work are in [the November 7 interaction slices](reviews/editor-program-2026-11-07/git-diff-next.md).

- [ ] **DEV-01: Build/test tasks on the accepted terminal interface.**
  Depends: EXT-04, BASE-04, UX-02. Scope: task config, variables/cwd/env, rerun, output navigation. Done: build/test executes in the selected project, interrupt/exit status work, task output opens file/line, task history survives relevant layout switches and failures remain inspectable. Reuse terminal sessions rather than creating another process UI.

## M3: Git completion and measured performance

- [ ] **GIT-05: Hunk stage/unstage.**
  Depends: GIT-02..04. Scope: hunk identity, patch validation and actions. Done: stage/unstage one current hunk without touching others; reject stale index/patch state; handle added/deleted/EOF/no-newline cases; refresh both index/worktree comparisons and preserve unsaved-buffer distinctions.

- [ ] **GIT-06: Conflict-resolution workflow.**
  Depends: GIT-02/03, TEXT-07, UX-04. Scope: conflict regions/editor and stage-as-resolved. Done: ours/theirs/both/manual edits preserve bytes and undo, unresolved markers/counts are clear, stage only against verified current content, and merge/rebase/stash conflict states are distinguished. Three-way layout can follow the basic region workflow.

- [ ] **GIT-07: File history and paginated commit review.**
  Depends: GIT-01/02, UX-02; EXT-06 menu integration. Scope: per-file log, pagination, commit/parent comparisons and permalinks. Done: no 100-commit dead end; correct file/commit patch opens and returns to source; remote link only appears when resolvable; rename-history policy is explicit.

- [ ] **GIT-08: Side-by-side diff with source navigation.**
  Depends: GIT-04, EXT-05, PERF-01. Scope: comparison projection and layout. Done: unified/split modes agree on source lines/hunks, insert/delete/long lines and narrow panes map correctly, staging actions keep identity, large patches remain usable. Direct editing of combined excerpts is WORK-02. Include per-file and global collapse/expand, rounded file headers with current-file Open File actions, and the below-tab hunk/staging/commit toolbar from the November 7 user screenshots.

- [ ] **GIT-09: Remaining safe repository management.**
  Depends: GIT-02..04, GIT-06; EXT-06. Scope: restore/discard preview, branch delete, stash drop, local tags and operation recovery. Done: destructive actions explain saved/unsaved impact and confirm target identity; conflicts retain recoverable state; remote/tag publication is explicit; unsupported Git operations remain discoverable through terminal guidance.

- [ ] **PERF-01: Incremental fold/wrap and lexical display state.**
  Depends: BASE-03, TEXT-07, LANG-03; EXT-01/05. Scope: row index, fold cache, lexical cache and display mapping. Done: edit at start/middle/end updates relevant ranges without rebuilding every row or clearing valid prefixes; font/width/global changes rebuild deliberately; undo/fold/hunk mappings match a fresh reference map.

- [ ] **PERF-02: Markdown and streaming-agent work outside input/paint.**
  Depends: BASE-03, TEXT-07. Scope: parse/layout scheduling and streamed text updates; provide scheduling interfaces for CONTENT-01 and AGENT-01. Done: background work coalesces with revision checks; scrolling reuses layouts; append updates avoid replacing the whole rendered history where possible; streaming never delays typing and cancellation releases work.

- [ ] **PERF-03: Bound native surrounding-text costs.**
  Depends: TEXT-01..03, BASE-03. Scope: native text excerpt/range supply. Done: select-all in a large file does not require an equally large surrounding-text snapshot each frame; actual native range/IME APIs still receive valid UTF-16/document mappings. Measure bytes and frame time, not only cache size.

- [ ] **PERF-04: Profile frame rebuild, shaping and GPU batching.**
  Depends: BASE-03, PERF-01/02. Scope: native frame/layout/paint/renderer hot paths. Done: identify measured dominant work, remove justified redundant layout/shaping/glyph extraction or introduce reuse where proven; correct clipping/fallback/selection/image lifetime survives; before/after release traces use equivalent features.

- [ ] **PERF-05: Memory and lifecycle budgets.**
  Depends: BASE-03, LANG-02, TEXT-05. Scope: rope/selection histories, frames/GPU leases, caches, processes and images. Done: repeated open/close/theme/extension/server/agent cycles release resources; byte-aware history/recovery policies are documented; process-tree and GPU measurements account for active/in-flight allocations and do not present cache limits as RSS caps.

- [ ] **PERF-06: Performance and freshness regression workloads.**
  Depends: PERF-01..05, GIT-02/03, LANG-01. Scope: repeatable release datasets and reporting. Done: typing/scroll/search/save/Git/large-project/streaming results include tails, blocked UI spans, coverage and memory on named hardware; budgets have calibrated tolerances. Add stable smoke checks without brittle universal timing assertions.

- [ ] **PERF-07: Renderer/GPU presentation failure recovery.**
  Depends: BASE-04, PERF-04/05. Scope: drawable/device/resource failure paths and window lifecycle. Done: failed presentation never publishes an invalid CPU frame or releases in-flight resources; retry/recreate or a clear recoverable error is supported; resizing, display changes and sleep/wake preserve editable document state. Exercise supported failure injection and record platform-specific recovery limits.

- [ ] **CONTENT-01: Cached Markdown blocks and viewport work.**
  Depends: PERF-02, TEXT-07. Scope: stable parsed blocks, cumulative heights, image identities and source hits. Done: edit updates affected blocks, scrolling limits work to relevant blocks, font/width/image changes invalidate correct geometry, links/source hits remain correct and decoded images persist when unchanged. Document full-layout fallback cases.

- [ ] **AGENT-01: Selectable transcripts and explicit change review.**
  Depends: EXT-07, UX-04, TEXT-07, GIT-04. Scope: agent message selection/copy, context visibility, edit-review integration. Done: arbitrary response text can be selected/copied; attachments and changed files are visible; dirty buffers survive tool writes; reviews identify actual current diffs and supported undo/revert scope.

- [ ] **AGENT-02: ACP capability and question/RPC compatibility.**
  Depends: AGENT-01, BASE-04; EXT-04 terminal integration. Scope: advertised filesystem/terminal RPC, permission/elicitation schemas, resume/reconnect and attachments. Done: implement declared capabilities or explicit errors, show all supported user decisions, clean up processes/canceled turns, validate real supported providers and avoid claiming a discovered model/provider is certified.

- [ ] **EXTAPI-01: Extension compatibility inventory and lifecycle checks.**
  Depends: BASE-01. Scope: contribution/API versions, manifests, host capabilities and package validation. Done: catalog distinguishes supported/mixed/unsupported packages; representative real languages/themes/icons and failure/rollback/disable/update paths pass; supported versions/imports and executable/download trust boundaries are documented.

- [ ] **EXTAPI-02: Theme/icon/token fidelity and settings precedence.**
  Depends: EXTAPI-01, UX-03/07. Scope: syntax categories/styles, color tokens, icon variants/chevrons and paired themes. Done: supported contributions map faithfully across tree/tabs/search/Git/pickers, fallbacks are explicit, font styles and metric invalidation agree and no unsupported token silently claims full compatibility.

- [ ] **QA-01: End-to-end acceptance of the local coding loop.**
  Depends: M1 tasks, LANG-04..08, SEARCH-03, UX-01/02, DEV-01, GIT-05/06. Scope: disposable real repository journey. Done: recover edits, navigate, refactor/format, replace, build/test, jump to errors, partially stage, resolve a conflict and commit; verify disk/index/buffer bytes and history throughout.

- [ ] **QA-02: Long-session, failure and cancellation checks.**
  Depends: TEXT-04..06, GIT-03, LANG-01/02, PERF-05. Scope: external events, slow/failed children, disk failure, extension reload, close/reopen. Done: no stale result installs, silent local-edit loss, orphan processes or progressive retained-resource growth under a recorded workload; recovery after abnormal exit works.

- [ ] **QA-03: Current documentation and CI reflect accepted behavior.**
  Depends: BASE-02; per-feature completion. Scope: status/editor/extension/agent guides and CI. Done: native/Rust/package checks exercise actual delivered paths; supported behavior and limits match code; stale audit claims are superseded by dated current notes, not erased. Update incrementally as slices land.

## M4: broader IDE and editing capability

- [ ] **WORK-01: Arbitrary pane trees and configurable docks.**
  Depends: EXT-04/05/07, TEXT-05, UX-02/04. Scope: layout model and persistence. Done: nested directional splits, moves, focus/close/maximize and dock relocation preserve document/session identity, dirty-close behavior and usable minimum geometry. Reconcile any already-delivered nesting before implementation.

- [ ] **WORK-02: Editable combined excerpts for search/diff/diagnostics.**
  Depends: TEXT-07, LANG-06, SEARCH-04, GIT-08, PERF-01. Scope: source/excerpt mapping and transactions. Done: edits map to current source documents with correct boundaries, undo/save/selection, duplicate excerpts and stale revision behavior; editing does not silently change an unrelated file.
  Progress: pinned Zed source and consumers are mapped in [the multibuffer research](research/zed-multibuffer-consumers-2026-11-08.md). Git current/context diff rows now edit their source documents directly, including initially unopened files, and worker results include unsaved text. Source undo/redo/save, separate top-level commit tabs, Vim pending keys and `g /` project search have portable/native journeys. UTF-16 projected points, cross-document selections/grouped history, context expansion, shared display maps and search/diagnostics migration remain open.

- [ ] **WORK-03: Multi-root projects and independent project contexts.**
  Depends: SEARCH-01, GIT-02, LANG-01, TEXT-05, WORK-01. Scope: project/worktree identities and UI. Done: search, Git, tasks, server sessions, recovery and terminals are scoped to explicit roots/projects; duplicate paths and project switches cannot cross-deliver results.

- [ ] **DEV-02: Debugger using DAP.**
  Depends: DEV-01, LANG-04/08, UX-04, EXTAPI-01. Scope: adapter lifecycle, launch/attach, breakpoints, stack/variables and controls; expose adapter integration for EXTAPI-03. Done: one real supported adapter passes launch/build/step/break/inspect/stop/restart; config errors and capability differences are visible; other adapters added through compatibility evidence.

- [ ] **DEV-03: SSH/WSL/container development.**
  Depends: TEXT-04/06/07, DEV-01, WORK-03, LANG-01. Scope: explicit local/remote file/process service boundaries, reconnect and container lifecycle. Done: remote edits/tasks/LSP/terminal and recovery use the right host; disconnect/reconnect preserves unsaved work; trust, credentials, forwards and server compatibility are clear. Deliver SSH first and track WSL/container acceptance separately.

- [ ] **LANG-10: Semantic tokens, inlay hints and call hierarchy.**
  Depends: LANG-01/04/08, PERF-01, UX-07. Scope: optional capabilities and rendered projections. Done: honor server/config support, reject stale data, combine with syntax consistently, navigate hierarchy and preserve selection/scroll/geometry. Enable only where real server journeys pass.

- [ ] **VIM-01: Broader Vim command compatibility.**
  Depends: TEXT-03/07, UX-02/03, LANG-04. Scope: named registers, macros, marks/jumps, Ex and Unicode arguments. Done: publish an explicit command matrix and behavioral journeys for counts, registers, repeat/undo, focus and composition; unsupported commands remain safe. Deliver coherent subsets rather than implying full Vim parity.

- [ ] **VIM-02: Structural editing and alternate modal scope.**
  Depends: LANG-03/09, VIM-01. Scope: syntax text objects, surround/pair/indent behavior and any Helix-style mode. Done: language structures map to valid edits and one undo, mappings/config reflect active mode, and alternate emulation has an explicit support matrix before exposure.

- [ ] **CONTENT-02: Broader Markdown rendering.**
  Depends: CONTENT-01, UX-07. Scope: CommonMark conformance, richer fenced languages and optional diagrams/math/remote images. Done: define and test accepted syntax; preserve source links; remote loading has explicit caching/privacy/resource policies; no untrusted HTML execution is introduced accidentally. Keep unsupported syntax visible in documentation.

- [ ] **CONTENT-03: Image navigation and viewing controls.**
  Depends: EXT-08, UX-04/07. Scope: zoom/pan/fit, metadata and supported animation frames. Done: image state remains distinct from text, decoding/resource limits are visible, close/navigation is consistent and large images do not freeze input. Image editing/export is a separate optional expansion.

- [ ] **AGENT-03: Isolated Git worktrees per conversation.**
  Depends: AGENT-01/02, GIT-02/03, WORK-03, TEXT-05. Scope: worktree create/open/switch/delete and conversation binding. Done: tasks/files/Git attach to the correct checkout; concurrent edits are isolated; cleanup cannot delete uncommitted work; setup tasks and review/apply-back conflicts are explicit.

- [ ] **AGENT-04: Inline assistance and edit prediction.**
  Depends: AGENT-01/02, TEXT-03/07, LANG-05, PERF-06. Scope: selected-text transformations and optional prediction provider. Done: suggestions never mutate before acceptance; revisions/context remain valid; accept/reject/undo and mode interactions work; provider authentication/privacy/cost and unsupported model capability are visible.

- [ ] **EXTAPI-03: Additional extension contribution types.**
  Depends: EXTAPI-01, LANG-05, DEV-02, AGENT-02. Scope: snippets, debug adapters/locators, MCP/context integrations and remaining supported imports. Done: each contribution type has a consumer, capability validation, disable/update cleanup and representative real-package acceptance before it is labeled supported. Snippet/API work can proceed before the debugger consumer, but that partial scope does not close the complete task.

## M5: distribution and remaining expansion

- [ ] **PLATFORM-01: Production macOS distribution and support diagnostics.**
  Depends: QA-01..03, UX-05/06. Scope: bundle resources/workers, signing/notarization, clean installation, logs and updates/rollback. Done: install/launch from a clean supported setup; release/update failure cannot damage settings or recovery data; support output excludes credentials and records exact build/platform details.

- [ ] **PLATFORM-02: Native Linux and Windows adapters.**
  Depends: PLATFORM-01 readiness, TEXT-02/03/06, UX-05/06, DEV-01. Scope: window/render/input/clipboard/IME/accessibility/filesystem/process/distribution per OS. Done: actual supported desktop journeys pass on each declared OS; portable compilation remains separately labeled; resource recovery and platform limitations are documented.
  Constraint: new implementation is Zig, with native libraries allowed through Zig bindings. GPU rendering is required. The discarded C/Cairo prototype does not count as delivered support. Vulkan/platform research is in progress.
  Progress: [platform plan](design/native-platforms.md) selects SDL3 for the first shared window/event backend while preserving macOS. Linux and Windows target compilation now pass 14/14 steps each. Native execution, text-system parity, PTY transport, dialogs, accessibility and packaging remain open.

- [ ] **PLATFORM-03: Full bidi and broader encoding behavior.**
  Depends: TEXT-03/08, UX-07, PERF-01. Scope: bidi layout/cursor/selection and legacy detection/re-encoding. Done: mixed-direction editing follows an explicit Unicode policy and shared geometry; unsupported conversions require deliberate handling; round trips preserve representable data. Track Zed's own bidi limitations without treating them as the correctness target.

- [ ] **COLLAB-01: Live collaboration, sharing and communication.**
  Depends: TEXT-07, WORK-03, DEV-03, QA-02. Scope: shared editing, permissions/identity, presence/follow and any calls/channels. Done: design and verify concurrent edit/undo/reconnect/authorization semantics; sharing scope is explicit; operational hosting/security/support commitments exist before promising parity.

- [ ] **DEV-04: Kernel REPL and notebook-oriented workflows.**
  Depends: DEV-01, WORK-01, UX-05. Scope: kernel lifecycle, execute cells/ranges, output and cancellation. Done: one real supported kernel runs, interrupts/restarts and maps output to current source safely; kernel dependencies and supported file formats are explicit.

- [ ] **AGENT-05: Scheduling, delegation and richer agent outputs.**
  Depends: AGENT-02/03, BASE-04, QA-02. Scope: durable scheduling/delegation state, tool-output views and provider support. Done: jobs resume/cancel with explicit ownership, isolated edits remain reviewable, questions/approvals cannot be bypassed, output retention and failures are visible. Treat this as a separate product milestone.

- [ ] **GIT-10: Optional Git graph and advanced history exploration.**
  Depends: GIT-07/09, WORK-03, PERF-06. Scope: graph traversal, selection and current-repository history context. Done: pagination/topology and commit/parent navigation remain correct on real merge histories and large repositories; exposed actions obey the existing mutation policy. Keep optional until selected for a release; file history ships independently.

- [ ] **CONTENT-04: Optional image editing/export.**
  Depends: CONTENT-03, TEXT-04, UX-05. Scope: deliberately selected non-destructive image operations and export. Done: preserve originals unless explicitly saving, show output format/metadata effects, enforce decode/export limits and make edits undoable. This is a product expansion from the audit, not an assertion that Zed implements a full image editor.

- [ ] **QA-04: Maintain the compatibility and gap inventory.**
  Depends: QA-03; ongoing after each milestone. Scope: Zed baseline/version, supported operating systems/languages/providers/extensions and optional capabilities. Done: every accepted or intentionally deferred gap maps to a verified behavior or open ID; new upstream features are dated additions, not retroactive failures of completed milestones. Review explicit optional items GIT-10 and CONTENT-04 when selecting release scope.

## Audit coverage map

| Audited area | Checklist coverage |
| --- | --- |
| Native input, Unicode, encoding, large files and recovery | TEXT-01..09, PERF-03, PLATFORM-03 |
| Document/second-view/undo/reload update propagation | TEXT-07, EXT-05, LANG-06, WORK-02 |
| Git refresh, queueing, baseline/staging, hunks, conflicts and history | GIT-01..10, EXT-06; graph is optional |
| LSP sync, parsing/folds, navigation, editing, diagnostics and language settings | LANG-01..10, PERF-01 |
| Search/replace, index/ignores, live results and editable excerpts | SEARCH-01..04, UX-02, WORK-02 |
| Terminal/tasks/debugger/remote/REPL | EXT-04, DEV-01..04 |
| Menus, tabs/panes, projects, settings/keymaps, native OS and accessibility | EXT-01..08, UX-01..07, WORK-01..03 |
| Typography, rendering, memory, latency and long sessions | UX-07, PERF-01..07, QA-02 |
| Markdown/images | CONTENT-01..04, EXT-08; image editing/export is optional |
| Agent UI/protocols/context/review/isolation/prediction/orchestration | EXT-07, AGENT-01..05 |
| Extension compatibility, contribution types and theme/icon fidelity | EXTAPI-01..03, LANG-09 |
| Vim/structural editing | VIM-01..02, TEXT-03, UX-03 |
| Desktop platforms, release quality and collaboration | PLATFORM-01..03, COLLAB-01, QA-01..04 |

## Handoff record

Append a dated note when claiming or completing work. Use task IDs so ownership survives renamed threads or changed implementation details.

| Date | Task IDs | Status/owner | Commit or evidence | Remaining work |
| --- | --- | --- | --- | --- |
| 2026-11-06 | EXT-01..08 | External active, linked above | Request/messages and wrapped-line diff inspected; further terminal/UI files appeared during planning | Verify actual delivered scope before checking anything off. |
| 2026-11-06 | All other IDs | Open, unclaimed | Planning only | Start with BASE-01/02 and the first batch in the roadmap. |
| 2026-11-07 | BASE-01, BASE-02, TEXT-01 | Done, current audit/roadmap implementation | [Progress and evidence](progress/2026-11-07-baseline.md) | BASE-03 is next. Production input/IME acceptance remains separate. |
| 2026-11-07 | EXT-01, EXT-05 | Accepted against delivered source and fresh checks | 41 editor and 55 native application checks | Two pane groups; nesting remains WORK-01. |
| 2026-11-07 | EXT-02/03/04/06/07/08 | Verify, implemented with remaining acceptance | [Reconciliation](progress/2026-11-07-baseline.md) | Check remaining UI/terminal/image cases; do not rebuild existing features. |
| 2026-11-07 | EXT-01 rendering follow-up | Done, current roadmap thread | [Wrapping and gutter evidence](progress/2026-11-07-wrapping-performance.md) | Performance work remains PERF-01; no source whitespace inserted. |
| 2026-11-07 | BASE-03 | Verify, driver and partial baseline delivered | [40 attempts and failures](benchmarks/editor-2026-11-07/README.md) | Diagnose six service failures, then rerun a new full batch; TEXT-05 is the next feature slice. |

| 2026-11-07 | BASE-03 | Done, controlled local baseline | [Complete 40-case batch](benchmarks/editor-2026-11-07-isolated-spawn/README.md), `0b73351` process fix | Real-server cost and long sessions remain PERF-06/QA-02; earlier failures retained. |

| 2026-11-07 | LANG-02/08 lifecycle correction | Delivered, broader IDs remain open | `e08fdc5`, `1f8f99e`; [native lifecycle evidence](reviews/editor-program-2026-11-07/language-evidence/README.md) | General diagnostic freshness, asynchronous shutdown, persistent grammar workers and recovery remain open. |


## Additional framework requirements from 2026-11-07

- [ ] Native application menu bar and library menus share typed actions, shortcuts, enabled/checked state, focus, teardown and platform ownership. Integrate the editor's File, Edit, View, Window and Help actions where supported.
- [ ] Application and window icons support owned image assets and correct native/distribution resources on macOS, Linux and Windows.
- [x] A documented GPUI-style fluent API provides typed Tailwind-like styling while retaining the eager frame lifetime and rollback guarantees. Application views and controls use fluent composition; imports are kept in file headers. [Migration evidence](reviews/editor-program-2026-11-07/fluent-migration-evidence/README.md) records portable/native checks and compiling examples.
