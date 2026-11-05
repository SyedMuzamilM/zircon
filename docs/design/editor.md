# Editor implementation design

Zircon uses the independent Zircon UI framework through its ordinary entity, window, custom-element, event and text-input interfaces. The two editor candidates agree on package ownership and immutable document snapshots. Both used the inherited model; no different-family judge was configured.

## Synthesis

Use a persistent chunked balanced rope with byte, UTF-16 and LF summaries. Candidate A's small binary tree is the initial implementation, rather than B's sixteen-way B+ tree. This reduces balancing and failure-path complexity while preserving shared snapshots, indexed lines and path-copy edits. Internal node layout remains private, so fanout can change after profiling. Leaves merge when small to prevent one-character edits accumulating one leaf each. This decision establishes design goals, not measured performance.

`zircon_text` owns storage, revisioned batch edits, snapshots, history and literal search. `zircon_workspace` owns document identities, canonical paths, file loading, safe saves, project entries and dirty-close policy. `zircon_editor` owns selection sets, commands, composition, lexical highlighting, viewports and a custom canvas. `apps/zircon` composes tree navigation, tabs, split panes, palette, find/replace and status. No editor package imports platform modules.

## Ownership and editing

A snapshot retains an immutable rope root. Reference-count updates and destruction run on the creator thread. A worker may read a snapshot retained before launch and releases it through UI-thread job cleanup. Frames retain snapshots through custom-element cleanup. Visible lines and bounded native input context are copied into the frame, never the whole ordinary document.

Edits accept a matching monotonically increasing revision and sorted disjoint UTF-8 byte ranges in the old document. Validate and prepare every allocation before swapping the root/history. Undo and redo retain content-state identities independently of revisions, so undo to saved content becomes clean. A new edit after undo releases the redo branch. Typing and composition use explicit history groups; all cursor edits form one transaction.

Line ranges exclude LF and a preceding CR for display; original CRLF bytes remain unchanged. Byte columns are distinct from display columns. Tab expansion records source/display offsets for pointer and caret mapping. Initial movement is code-point safe; full grapheme segmentation requires separate Unicode data and tests.

## Framework reconciliations

The design review exposed two requirements before editor implementation. Bounded native snapshots carry both `base_byte` and `base_utf16`; snapshot selection/marked ranges are local while emitted replacements use absolute document bytes. Close requests reach application handlers and can be prevented; native windows hide only after the framework accepts closure. These changes are included in the framework verification before editor code depends on them.

## File policy and UI

Save captures one content state, writes/flushed a sibling temporary file, preserves existing permissions and atomically renames. Disk changes produce a conflict instead of silent overwrite. An older save marks only its captured state as saved. A preflight conflict check cannot exclude another writer racing the final rename; do not promise it does. Save/Discard/Cancel decisions protect dirty tabs and native window close.

The document area uses a dark graphite background, quiet blue-gray chrome, system UI type and monospaced source. Blue marks focus/selection; language tokens supply the other colors. Sidebar, tabs and status contain actual file/command state. Controls must perform their labelled operation. Empty/error states provide a next action.

## Verification

Prove storage with randomized differential edits, retained snapshots, metric scans, undo branches, multi-edit mappings and allocation failure. Verify workspace persistence against real temporary files, including conflict/failure retention. Exercise pure editor commands before native input. Then drive open, edit, select, scroll, find/replace, split, undo, save, reopen and dirty close through a real native window; inspect the rendered artifact and disk bytes.

LSP, Git, PTY terminals, extension hosts, collaboration and non-macOS adapters remain separate implementation work. A functioning text editor does not establish Zed feature or performance parity. Record actual coverage and measurements as implementation proceeds.
