# What Zircon should take from the Zed/GPUI comparison

Reviewed 2026-11-07 against local commit `560dc2a9d9111012ebfa93fb2243515ac5339753` plus the existing working-tree changes. This follows the [comparison](zed-gpui-vs-zircon-2026-11-07.md). The [upstream investigation](zed-gpui-follow-up-upstream-2026-11-07.md) pins Zed source to `b5cd310b3b54dfc659fcc06453e6358843dfe216` and documents the mechanisms behind these recommendations.

The comparison's product direction is sound. Finish a dependable local coding editor. The missing piece is execution order: complete recovery, establish one document-change contract, then use it for external changes and incremental services. Most of this already has task IDs in the [checklist](../editor-todo.md). Keep those IDs rather than create a competing backlog.

This review changes documentation only. It includes source inspection and new primary-source research, with no new runtime benchmark or native acceptance run.

## Work to do next

### 1. Finish recovery integration before adding another editor feature

Track under TEXT-05. The [recovery store](../../packages/zircon_workspace/src/recovery.zig) already implements checkpoints and restoration. The [shell](../../apps/zircon/src/shell.zig) has `initRecovery`, but the application source currently has no call to that method and no recovery checkpoint/restore integration. An optional store field and discard hook do not establish crash recovery.

Wire startup discovery and restore, debounced dirty/untitled checkpoints, session/pane state and explicit discard. Preserve the original disk fingerprint when restoring. Otherwise a recovered buffer could adopt an external disk edit as its save baseline. Reuse the existing [recovery design](../reviews/editor-program-2026-11-07/recovery-design.md) and storage tests.

Acceptance: edit a saved file and an untitled buffer, wait for an acknowledged checkpoint, terminate the process with SIGKILL, relaunch and verify exact bytes and useful pane/selection state. Change the saved file externally before relaunch and verify that saving the recovered text detects the conflict. Explicit discard must survive another restart. State the checkpoint interval and possible loss since the last checkpoint.

### 2. Make committed document changes the integration point

Track under TEXT-07, then TEXT-04/06 and GIT-01/02. [actions.zig](../../apps/zircon/src/actions.zig) already has `applyOutcome` for mapping edits into other views and refreshing preview state. Extend that existing path instead of introducing a second event system. Git scheduling still sits separately in `editorInput`; language synchronization polls document revisions.

The published change needs document identity, before/after revision, content-state identity, origin, edit mappings or an explicit reset, and a policy for remapping views. Subscribers need ordered delivery and a declared full-snapshot fallback if they miss retained edits. Recovery must checkpoint the committed content state; completion of an older async save must leave newer edits dirty.

Connect external edit/atomic replacement/rename/delete events through this path. Coalesce bursts, filter own saves, and rescan after dropped events. Keep local dirty text until the user resolves a conflict. Repository/index invalidation needs its own generation because Git can change without a document edit.

Acceptance: keep the same document in two panes plus a preview, change it through typing, undo, completion and external reload, and verify all views and service revisions agree. External replacement of a clean file should reload; external replacement of a dirty file should preserve local text. Include a rename and a dropped-event rescan.

### 3. Remove repeated whole-document and repository work from typing

These are separate, verifiable slices. They share change delivery, but do not need one large rewrite.

| Existing task | Source finding | Concrete next change | Evidence required |
| --- | --- | --- | --- |
| GIT-01 | `Job.perform` in [services/git.zig](../../apps/zircon/src/services/git.zig) runs `status` and `history` after ordinary refreshes; `editorInput` schedules refresh after changes. | Cache repository/index baselines and run buffer diffs independently. Refresh metadata after repository invalidation or mutations. | After initial setup, a typing-only burst starts no status/history queries; current gutters still settle. External staging invalidates the baseline. |
| LANG-01 | [Client.didChange](../../packages/zircon_language/src/client.zig) copies the entire snapshot and sends a text-only change. | Negotiate None/Full/Incremental and position encoding, then serialize ordered edit ranges for incremental servers. Bound pending output. | A fixture server reconstructs exact text after Unicode edits, undo, rapid input and reopen. Record serialized bytes and queue pressure. |
| LANG-02, then LANG-03 | [extension_host.zig](../../apps/zircon/src/services/extension_host.zig) and [highlight.rs](../../tools/zed-extension-host/src/highlight.rs) create per-request highlight work without retaining the parser tree across requests. | Retain the worker and grammar first; then edit retained trees and query affected regions. Preserve cancellation and grammar/document/config generations. | Repeated edits reuse a worker; incremental output agrees with a fresh parse. Disable/reinstall/crash cannot publish old results. |
| PERF-01 | [wrap.ensure](../../packages/zircon_editor/src/wrap.zig) reuses shaping, but traverses all logical lines and copies unaffected row entries. [folding.ensure](../../packages/zircon_editor/src/folding.zig) copies and scans the document after invalidation. | Retain row/index structure across edits and update affected ranges. Remove the full fold scan from the input/frame path; bound foreground work on width/font changes. | Start/middle/end edits, undo, folds and inline hunks agree with a fresh reference map. Count rows visited/copied and bytes scanned, alongside latency. |

The [current baseline](../benchmarks/editor-2026-11-07-lifecycle-current-git/README.md) justifies investigating these paths. Its services configuration uses a deterministic LSP fixture. It does not characterize real-server memory use or isolate each subsystem's timing contribution. Preserve equivalent feature coverage for before/after measurements. Do not turn its submission timings into key-to-pixel or Zed comparisons.

Incremental wrapping does not need to wait for every syntax-aware folding feature in LANG-03. A bounded row-index slice can proceed using existing text changes and indentation fallback. Keep full-map rebuilding as a correctness reference and explicit fallback.

### 4. Treat Unicode editing and native input as correctness work

Track under TEXT-02/03 and PERF-03. [navigation.zig](../../packages/zircon_editor/src/navigation.zig) uses code-point boundaries for horizontal movement. UTF-8 validity does not make a combining sequence, flag or joined emoji one editable character.

Use a shared extended-grapheme boundary implementation across editor movement/deletion, Vim, text fields and wrapped hit testing. Pin its Unicode version and generate tables from that version. [UAX #29 revision 47](https://www.unicode.org/reports/tr29/tr29-47.html) specifies Unicode 17.0 segmentation; its [official conformance data](https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakTest.txt) gives a reproducible test target. Choose the supported version explicitly rather than follow a moving latest URL.

Keep native IME acceptance separate. Real foreground CJK commit/cancel, dead keys, Option layouts and Vim transitions must preserve text and undo history. A synthetic selector test cannot close that acceptance. Bound surrounding-text snapshots while preserving valid UTF-16 ranges.

### 5. Deliver definition navigation and explicit formatting as small vertical slices

Track under LANG-04, UX-02 and LANG-07 after the synchronization contract. Definition should open the right file/location and provide a working return action. Explicit format should validate the captured revision, apply one undoable transaction and refuse stale output. These complete common coding actions sooner than implementing every language request at once.

Keep multi-file rename/code actions and project replace under LANG-06 and SEARCH-03. They need shared validation, dirty-file protection and partial-disk-failure recovery. Do not make single-file navigation wait for that entire transaction design.

## Framework work worth pulling forward

### Context keys and focus routing

Use UX-03/04. The [Key enum](../../packages/zircon_ui/src/platform/interface.zig) omits digits, F-keys and much punctuation; the [keymap](../../packages/zircon_ui/src/event/actions.zig) resolves one chord. Widen native key identity first, then add pending sequences and explicit context precedence. Keep typed actions and the current settings migration explicit.

Acceptance must include an ambiguous prefix, timeout/cancel, focus change during a sequence, unbinding, and keys intended for a text field, Vim or terminal. Do not consume ordinary text as a global shortcut while composition is active. GPUI's context resolver is a useful reference, but Zircon does not need its entire predicate language for the first version.

### Accessibility semantics in committed frames

Use UX-05. Add stable semantic identity, role, name, state and supported actions to element data, then publish the accessibility snapshot with the successful CPU frame. A failed staging frame must leave the previous accessible tree and action targets valid, just as it preserves existing handlers and IME state.

Start with one complete path through buttons, a text field, project selection and the editor, including actual macOS accessibility inspection and assistive-technology acceptance. IDs must survive frame rebuilds and distinguish simultaneous views of one document. Choose direct AX or an adapter after this contract is clear. Do not leave accessibility until all other parity work is done.

### Reusable lists before custom-container redesign

[visibleRows](../../packages/zircon_ui/src/controls/scroll.zig) already supplies overscanned virtualization. Existing project/Git/search/extension views and popovers work. Extract a composed list from a real consumer with shared scroll clamping, reveal, selection/focus and clipping behavior. Migrate a second consumer to establish that the contract is useful.

Only add `layoutChild` or a distinct prepaint traversal when a concrete control needs children generated from its final arranged bounds. The current custom adapter invokes prepaint immediately before paint. That limits custom containers, but it does not prevent composed controls.

## Small framework issues to keep separate

- Animation key spaces overlap in [Ui.animateColor/animateRect](../../packages/zircon_ui/src/ui/ui.zig). Color key `1` uses scalar tracks `4..7`, including scalar key `4`; rectangle key `1` uses the same tracks. Reserve a kind and channel in the internal identity rather than require callers to coordinate numeric ranges. Verify different animation kinds on the same entity remain independent, including interrupted and discarded frames. This is a source-level collision finding, not a reproduced visible editor regression.
- [App.openWindow](../../packages/zircon_ui/src/app/app.zig) appends slots. Closed window objects are deinitialized in `step`, so this is growth of empty slots, not proof that every closed window leaks its full resources. Reuse slots with generations if repeated-window workloads show material growth; old handles must stay invalid.
- The two `LayoutResult` names are in different namespaces. Naming clarity and exposing a supported window API are reasonable library cleanup, but neither outranks lost-work prevention or the coding loop.

## Corrections to the comparison

1. Replace the claim that missing child layout blocks lists/popovers. Existing composition and virtualization already support them. The missing capability is custom child generation/layout after final bounds are known.
2. Describe wrapping as partially incremental today. It saves shaping for unaffected lines, but still rebuilds flat row/index arrays and scans folding state.
3. Treat GPUI Fast social CPU figures as an unverified report. No reproducible harness or raw data was checked here. `uniform_list` bounds row construction; that alone cannot guarantee 120 Hz.
4. Treat framework ownership and rollback as useful explicit contracts. Claims that Zircon is generally more testable or better designed than GPUI need a defined comparison; source size and selected tests do not establish that ranking.
5. Use pinned source revisions for architectural evidence. Moving `main` links and release/social summaries should not determine implementation priorities.

## Research basis and limits

The [upstream follow-up](zed-gpui-follow-up-upstream-2026-11-07.md) cites pinned implementations of display-map interpolation, background wrapping, retained parse trees, capability-aware LSP changes, key contexts, AccessKit and uniform lists. I additionally checked the official [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/). It defines synchronization capabilities and encoding negotiation; UTF-16 is the default when the server omits position encoding. Incremental changes must be interpreted in sequence against the preceding document state, not all against one old snapshot.

Context7 documentation lookup failed with `Invalid API key`; direct first-party sources supplied the research. The Unicode links deliberately pin a stable version. This is not a license audit, accessibility certification or performance ranking.

Defer subtree caching, broad grid/path rendering, new desktop backends and arbitrary plugin UI until a supported workflow supplies a concrete requirement. Start implementation with TEXT-05, then the TEXT-07 contract and its first consumer. Keep Unicode and keyboard/accessibility work active alongside the service and coding-loop slices.
