# Independent Review: Recovery Storage Audit and Editable-Diff Architecture

**Reviewer**: Antigravity (Independent Review Sub-agent)  
**Date**: 2026-11-07  
**Workspace**: `/Users/syedmuzamilm/work/expirements/zigpui`  
**Target Revision**: `f5d9068` (`docs(editor): track screenshot-specific diff and notification acceptance`)  
**Scope**: Commits `c23490e` (bounded grammar retries), `8ea2d7e` (storage-only crash recovery), `5700514` (Git UI/status/cursors/popovers), and `f5d9068` (screenshot-specific diff/notification acceptance).

---

## 1. Executive Summary & Verification Evidence

This report provides an independent audit of recent commits `c23490e`, `8ea2d7e`, `5700514`, and `f5d9068`, evaluates the current recovery storage implementation in `packages/zircon_workspace`, and proposes a concrete, production-ready architecture for source-backed editable diffs in Zircon.

### 1.1 Verified Test & Verification Status

We strictly distinguish executed runtime proof from source inference:

1. **Targeted Portable Test Execution (Executed Proof)**:
   - `test-workspace`:
     ```
     $ ./tools/zig build test-workspace --summary all
     Build Summary: 3/3 steps succeeded
     test-workspace success
     +- run test 21 pass (21 total)
        +- compile test debug native
     ```
     All 21 package tests pass, including the 8 new recovery storage and restore verification checks.
   - `test-git`:
     ```
     $ ./tools/zig build test-git --summary all
     Build Summary: 3/3 steps succeeded; 16/16 tests passed
     test-git success
     +- run test 16 pass (16 total) 3s MaxRSS:6M
        +- compile test debug native success 1s MaxRSS:291M
     ```
     All 16 package tests pass, verifying repository discovery, status, staging, unstaging, and diffs on unborn repositories and paths with spaces/Unicode.
   - `test-git-parsers`:
     ```
     $ ./tools/zig build test-git-parsers --summary all
     Build Summary: 3/3 steps succeeded; 8/8 tests passed
     test-git-parsers success
     +- run test 8 pass (8 total) 446ms MaxRSS:3M
        +- compile test debug native success 1s MaxRSS:278M
     ```
     All 8 tests pass, verifying patch parsing, hunk extraction, bounded line diffing, and deletion anchoring.

2. **Existing Baseline & Mutation Evidence (Artifact Audited)**:
   - `portable.txt`: 76 passed, 4 explicit native-only skips, 80 total.
   - `native.txt`: 105/105 passed across the sequential native window, renderer, editor, settings, and rendering chains.
   - `release.txt`: 42/42 build steps, 271 tests passed, 4 native skips.
   - Correctness smoke matrix: 8/8 configurations with 160 inputs passed (`benchmarks/editor-2026-11-07-git-ui-smoke/`).
   - Mutation verification:
     - The divider cursor mutation removed resize metadata and failed the native horizontal-resize assertion (`git-ui-evidence/cursor-mutation.txt`).
     - The branch/stash popup anchor mutation restored reanchoring from internal tab bounds, moving the popup from $y=32$ to $y=76$ and failing placement assertions (`git-ui-evidence/anchor-mutation.txt`).
     - The initial native cursor mutation was inconclusive due to an earlier standalone text-dispatch failure, which was retained for transparency (`native-mutation-inconclusive.txt`).

3. **Current Product Status**:
   - `TEXT-05` (durable recovery) is partially complete: `8ea2d7e` implements storage-only primitives; Shell/UI integration, background worker scheduling, and real crash/SIGKILL testing remain open.
   - `GIT-08` / `WORK-02` (editable diffs): Current `apps/zircon/src/views/git_diff.zig` renders static `codeRow` elements from parsed git diffs. **Source-backed editable diff buffers are not implemented yet.**
   - In accordance with review policy, no full-product score (e.g. 10/10) is awarded.

---

## 2. Independent Audit: Recovery Storage (`8ea2d7e`)

Commit `8ea2d7e` introduces `packages/zircon_workspace/src/recovery.zig` and amends `root.zig` with `Workspace.restore`. We independently audited the ordering, tombstones, locking, corruption quarantine, and baseline preservation.

```
       +-----------------------------------------------------------+
       |                  Store.publish Workflow                   |
       +-----------------------------------------------------------+
                                     |
                                     v
                        Validate Index & Project Root
                                     |
                                     v
                 Check Document Tombstones (discard-doc-{id})
                                     |
                                     v
                 Atomically Write Document Content Files
                    (doc-{id}-{digest}.text + fsync)
                                     |
                                     v
                    Advance next_document_id Reservation
                                     |
                                     v
                 Atomically Write & Replace index.json (+ fsync)
                                     |
                                     v
                 Deferred Cleanup (collect unreachable text)
```

### 2.1 Storage Ordering & Atomic Guarantees
- **Content-Before-Index Invariant**: In `Store.publish`, content files (`doc-{id}-{digest}.text`) are written atomically via temporary files (`createFileAtomic`) and synchronized (`atomic.file.sync`) before the index is touched. The index is then written atomically with replace (`createFileAtomic(..., .{ .replace = true })`).
- **Deferred Collection**: Orphan and superseded content cleanup (`collect`) is executed strictly *after* `index.json` is successfully replaced. Any error in `collect` is swallowed (`catch {}`), ensuring that a cleanup failure (e.g., read-only directory or busy file) never invalidates an already-committed backup.
- **Torn Write Immunity**: Because the index is only updated after content files are committed on disk, a process crash during content writing leaves unreferenced orphan content files that are safely ignored by `Store.load` and pruned on the next successful collection pass.

### 2.2 Tombstones & Discard Semantics
- **Document Discard (`Store.exclude`)**: When a user explicitly discards an unsaved document or closes a buffer, `Store.exclude(id)` creates a durable tombstone file `discard-doc-{id}` containing `"discarded\n"`.
- **Stale Worker Protection**: Both `Store.publish` and `Store.load` explicitly check for `try exists(dir, self.io, try exclusionName(&tombstone, doc.id))`. If a background worker is mid-flight or delayed when a user discards a buffer, the tombstone prevents that worker from resurrecting the discarded document.
- **Session Discard (`Store.discard`)**: An acknowledged window close with discard writes a session-level `discarded` file. Subsequent `Store.load` returns `null` and `Store.publish` returns `error.RecoverySessionDiscarded`.

### 2.3 Locking & Multi-Window Isolation
- **Lock Implementation**: Each session directory `home/<sha256(root)>/session-<hex16>` contains a `lock` file opened with:
  ```zig
  session_dir.createFile(io, "lock", .{
      .truncate = false,
      .lock = .exclusive,
      .lock_nonblocking = true,
      .permissions = .fromMode(0o600),
  })
  ```
- **Window Isolation**: When multiple windows open the same repository root, `Store.init` iterates existing sessions. Any session whose lock is currently held by a running process returns `error.WouldBlock` and is skipped. If all existing sessions are locked or discarded, a new unique session directory is created.
- **Session Adoption**: When a window restarts after a crash or clean termination, `Store.init` claims the newest unlocked session that has a valid `index.json`.

### 2.4 Corruption Handling & Identity Reservation
- **Content Corruption Quarantine**: If a content file's SHA-256 digest does not match its `ContentRef`, or if the content contains invalid UTF-8 or embedded NUL bytes, `Store.load` does *not* delete the file. Instead, it writes a `corrupt-doc-{id}` marker, increments `warnings`, and continues loading the remaining documents. Crucially, `collect` checks for `corrupt-doc-{id}` and refuses to prune corrupt text, preserving raw bytes for manual salvage.
- **Index Corruption Quarantine**: If `index.json` is malformed (torn JSON or schema invalid), `Store.corruptIndex` writes the raw corrupt payload to `corrupt-index-{random}.json` before failing with `error.CorruptRecoveryIndex`.
- **Persistent ID Reservation**: Both `Store.publish` and `Store.load` update `next_document_id = @max(index.next_document_id, doc.id + 1)`. Even if a document is excluded by tombstone or quarantined due to corruption, its numeric ID is never recycled, preventing cross-document contamination.

### 2.5 Baseline Preservation on Restore
- **Avoiding Disk Baseline Adoption**: A subtle and critical flaw in naive recovery systems is reading the file from disk upon restart and overlaying recovery text, which adopts whatever modified time or external content exists on disk as the new baseline.
- `Workspace.restore` solves this correctly:
  ```zig
  pub fn restore(workspace: *Workspace, bytes: []const u8, path: ?[]const u8, dirty_value: bool, disk: ?DiskStamp, untitled_name: []const u8) !DocumentId
  ```
  It constructs a `text.Document` directly from the recovery bytes and installs the original `disk: ?DiskStamp` captured at checkpoint time.
- **Conflict on External Edit**: If an external git checkout or editor modified the file on disk while Zircon was crashed, an attempt to save the restored buffer via `Workspace.save` will compare `record.disk` against the file's current disk stamp, detect the external modification, and return `error.DiskConflict`. The recovered content remains safely in memory and cannot silently overwrite the external edit.

### 2.6 Storage Audit Findings & Open Integration Work
1. **Source Suggestion vs Runtime Proof**:
   - *Runtime Proof*: `test-workspace` passes 21/21 checks. The 8 recovery tests verify store creation, multi-window locking, content and index atomic replacement, tombstone enforcement, corruption quarantine, and `DiskConflict` preservation.
   - *Source Audit Limitation*: The current storage layer does not invoke `fsync` on the parent directory file descriptor (`std.Io.Dir`). On POSIX systems, while file contents are flushed, directory metadata ordering across ungraceful host power loss is not strictly guaranteed.
2. **Open Gaps for Full `TEXT-05` Acceptance**:
   - Integration into `apps/zircon/src/shell.zig` and the UI lifecycle is pending.
   - UI snapshotting, periodic background debouncing (e.g. 1-second window), and background writer actor serialization are not yet wired.
   - Restore of dual-pane layout, tab ordering, cursor selections, scroll offsets, and per-document language overrides needs Shell-level integration.
   - Real `SIGKILL` subprocess test harness is required to prove crash restoration end-to-end.

---

## 3. Architecture Comparison: Editable Diff Buffers

The November 7 requirements (`docs/reviews/editor-program-2026-11-07/git-diff-next.md` item 4) establish that:
> *"Editable uncommitted diff buffers require document-backed excerpts. Keep each source document in Workspace, map new-side excerpt byte positions to its snapshot, render deletions as immutable comparison text, and route edits through Editor.applyOutcome... A generic text input over displayed patch text cannot pass this requirement."*

We evaluate two architectural candidates against data safety, undo/redo coherence, IME/surrounding text, and staging semantics.

```
Candidate A: Per-Source Excerpt Projection (Recommended)
============================================================================
Diff View (Virtual Projection)
  [File: src/main.zig]
    Hunk 1:
      - immutable deletion (old comparison text)
      + editable addition   ----(direct byte map)----> Workspace Document A
      + editable addition   ----(direct byte map)----> (DocId: 1, Snapshot R5)
  [File: src/util.zig]
    Hunk 1:
      + editable addition   ----(direct byte map)----> Workspace Document B

Candidate B: Synthetic Mutable Patch Text (Rejected)
============================================================================
Diff View
  [Monolithic Patch Buffer] <--- Edits directly alter unified patch text
             |
      (Fuzz / Reverse Parser)
             v
   Attempted Back-Propagation to Document A and Document B
   (High risk of parse failure, ambiguous offsets, and data loss)
```

### 3.1 Candidate Comparison Matrix

| Evaluation Dimension | Candidate A: Per-Source Document Excerpt Projection | Candidate B: Separate Mutable Patch Text |
| :--- | :--- | :--- |
| **Data Safety & Integrity** | **Safe**: Every edit directly mutates the source document rope (`text.Document`) via established primitives. No reverse patch parsing or fuzzy reapplication. | **Unsafe**: User edits to patch text (deleting headers, corrupting `+`/`-` prefixes, modifying deletion lines) can cause the patch parser to fail, silently corrupt offsets, or lose unsaved edits. |
| **Undo / Redo Coherence** | **Unified**: Edits made in the diff view participate in each source document's native undo history. Opening the file in a regular editor tab exposes the identical undo stack. | **Split-Brain**: The patch buffer has an isolated undo stack. Undoing in the diff view does not match the source document's history, causing state divergence. |
| **IME & Composition** | **Robust**: `Editor.marked` and UTF-8 composition events bind to exact byte ranges within the source line. IME active ranges never cross synthetic diff markers. | **Broken**: Composing CJK or dead keys near `+` prefixes or hunk boundaries breaks patch syntax during composition, triggering invalid state transitions. |
| **Multi-Cursor Semantics** | **Clean**: Cursors are restricted to editable excerpt regions (additions and context lines). Deletion lines reject cursors or treat them as read-only. | **Chaotic**: Cursors can land on diff metadata (`@@`), deletion markers, or file headers. Batch typing destroys patch framing. |
| **Staging Semantics** | **Predictable**: Differs cleanly between memory buffer, saved disk state, and git index (GIT-04). Hunk staging operates on validated document snapshots. | **Ambiguous**: Staging a hunk from an unsaved synthetic patch creates undefined intermediate states between disk and memory. |

### 3.2 Decision: Adopt Candidate A (Per-Source Excerpt Projection)
Candidate A is the only design that satisfies data safety, preserves native undo transactions, and integrates cleanly with Zircon's existing `Workspace`, `Editor`, and `applyOutcome` infrastructure. Candidate B is rejected as structurally incompatible with editor parity.

---

## 4. Proposed Technical Specification: Document-Backed Editable Diff

### 4.1 System Topology & Workspace Mapping

The diff view becomes a multi-excerpt projection container that manages one or more open `Workspace.DocumentId` instances:

1. **Document Identity Management**:
   - For each changed file in the active comparison (worktree vs index/HEAD), `DiffSession` ensures the file is registered in `Workspace` via `workspace.open(path)`.
   - If the file was not already open in an editor tab, it is held by the `DiffSession` as an active document reference.
   - Clean buffers are tracked; unsaved dirty buffers are observed through their live snapshots (`record.doc.snapshot()`).

2. **Row Projection & Line Pairing**:
   - Old comparison lines (deletions) are rendered as immutable static text styled with `theme.deleted`. They cannot receive typing focus or cursor insertion.
   - New comparison lines (additions and context) are editable projection rows directly linked to a specific `(DocumentId, byte_start, byte_end)` in the source document.
   - Split mode and unified mode share the exact same underlying excerpt data structures; only the layout painter differs.

### 4.2 Core Data Structures

```zig
pub const ViewMode = enum { unified, split };

pub const ExcerptRegion = struct {
    doc_id: ws.DocumentId,
    source_start_byte: usize,
    source_end_byte: usize,
    source_start_line: usize,
    line_count: usize,
};

pub const DiffLineKind = enum {
    context,
    addition,
    deletion,
    spacer, // Used in split mode to align rows
};

pub const DiffRow = struct {
    kind: DiffLineKind,
    text: []const u8,
    old_line: ?usize = null,
    new_line: ?usize = null,
    // Source mapping (non-null only for editable addition/context lines)
    doc_id: ?ws.DocumentId = null,
    byte_range: ?text.Range = null,
};

pub const DiffHunk = struct {
    hunk_index: usize,
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    header: []const u8,
    lines: []const DiffRow,
    // Pre-calculated split pairing
    split_left: []const DiffRow,
    split_right: []const DiffRow,
};

pub const FileDiff = struct {
    path: []const u8,
    doc_id: ?ws.DocumentId,
    collapsed: bool = false,
    staged: bool = false,
    additions: usize = 0,
    deletions: usize = 0,
    hunks: []DiffHunk,
    is_binary: bool = false,
    is_new: bool = false,
    is_deleted: bool = false,
};

pub const DiffModel = struct {
    allocator: std.mem.Allocator,
    mode: ViewMode = .unified,
    files: std.ArrayList(FileDiff),
    active_file: usize = 0,
    active_hunk: usize = 0,
    focused_doc: ?ws.DocumentId = null,
    // Active selection projected into the focused source document
    selections: zircon_editor.selection.Set,
    scroll: ui.controls.Scroll = .{},
    diff_revision: u64 = 0,
};
```

### 4.3 Core Functions & Routing Pipeline

```
  User Input (Pointer / Typing / IME)
                  |
                  v
       +--------------------+
       |  diffViewInput()   |
       +--------------------+
                  |
                  v
       Map Visual (x, y) to (DocumentId, ByteOffset)
                  |
                  v
       Build zircon_editor.Outcome via Editor.handle()
                  |
                  v
       +--------------------+
       | Shell.applyOutcome | ---> Dispatches to:
       +--------------------+      - Workspace.Record.doc
                                   - Open Editor Tabs for DocumentId
                                   - Secondary Panes / Previews
                                   - DiffModel (maps selections & re-diffs)
```

1. **Input Mapping (`mapPointToSource`)**:
   ```zig
   pub fn mapPointToSource(
       model: *const DiffModel,
       point: ui.Point,
       bounds: ui.Rect,
       line_height: f32,
   ) ?struct { doc_id: ws.DocumentId, offset: usize }
   ```
   Given a click or drag coordinate inside the diff canvas, this finds the targeted `DiffRow`. If the row is a deletion or spacer, the cursor is clamped to the nearest editable line or rejected. If the row is editable, the horizontal offset maps to the byte index in the underlying rope.

2. **Input Dispatch (`diffViewInput`)**:
   ```zig
   pub fn diffViewInput(
       self: *Shell,
       e: *ui.Event(ui.Input),
       cx: *ui.Context(Shell),
   ) !bool
   ```
   When the user types, pastes, or enters IME composition, the event is routed to an `Editor` instance bound to the active `doc_id`. `editor.handle(&record.doc, e)` computes the `editing.Outcome`.

3. **Outcome Application (`applyOutcome`)**:
   Edits route directly through `Shell.applyOutcome(self, cx, doc_id, pane, &outcome)`. This guarantees:
   - Changes are applied atomically to `record.doc`.
   - Other editor tabs displaying the same document synchronize immediately via `mapChange`.
   - The diff model receives the `text.Change` and maps its internal selection set using `change.map(cursor, .after)`.

4. **Incremental Diff Recomputation**:
   Following an edit, a debounced background diff is scheduled against the document's unsaved snapshot. If typing continues, obsolete diff computations are discarded. When the fresh diff arrives, hunk row boundaries update smoothly while preserving active cursor positions.

### 4.4 Preservation of Key UI Features

```
+-------------------------------------------------------------------------------+
|  [Tabs: main.zig | git_diff.zig]                                              |
+-------------------------------------------------------------------------------+
|  Toolbar: [Collapse All] [Unified|Split] | +14 -3 | [< Hunk] [> Hunk] | [Stage Hunk] [Stage All] [Commit] |
+-------------------------------------------------------------------------------+
|  ▼ File: apps/zircon/src/main.zig   [+10 -2]         [Open File (on hover)] [Stage File] |
|  -----------------------------------------------------------------------------|
|  @@ -42,6 +42,10 @@                                                           |
|     context line                                                               |
|  -  immutable deleted line                                                    |
|  +  editable added line 1  <--- [Active Cursor]                               |
|  +  editable added line 2                                                     |
|     context line                                                               |
+-------------------------------------------------------------------------------+
|  Breadcrumbs (in normal editor tabs): apps > zircon > src > main.zig > fn main |
+-------------------------------------------------------------------------------+
```

1. **Unified vs Split Modes**:
   - `DiffModel.mode` switches rendering layout without altering document attachments.
   - In unified mode, old and new rows stack sequentially in a single column.
   - In split mode, the view splits into two side-by-side panes. The left pane renders immutable base rows; the right pane renders editable new-side rows, inserting empty spacer rows to keep paired hunks visually aligned.
2. **Global & Per-File Collapse**:
   - `FileDiff.collapsed` toggles visibility of all hunks for that file.
   - Toolbar "Collapse All" / "Expand All" sets all `FileDiff.collapsed` booleans and updates scroll height.
   - Collapsing preserves dirty buffer edits in memory.
3. **File Headers & "Open File"**:
   - Each file section has a rounded header displaying: collapse chevron, file icon, path, addition/deletion badge (`+X -Y`), and stage button.
   - An "Open File" button appears when hovering the header or when that file contains the active cursor. Clicking it opens or focuses the standard editor tab for that file, placing the cursor at the current hunk's source position.
4. **Toolbar (Below Tabs)**:
   - Resides directly under the tab strip, separate from window navigation.
   - Houses view mode toggle, hunk navigation (`Previous Hunk`, `Next Hunk`), `Stage Hunk`, `Stage All`, and `Commit`.
   - Controls reflect active selection state (e.g., `Stage Hunk` operates on the currently focused hunk).
5. **Ordinary File Breadcrumb Bar**:
   - Ordinary editor tabs maintain their dedicated breadcrumb bar displaying file path and real syntax symbol hierarchy.
   - The diff view toolbar replaces breadcrumbs only when the active tab is a diff buffer, preventing clutter.

---

## 5. Persistent Syntax-Worker Architecture Recommendation

Commit `c23490e` resolved transient grammar worker crash loops by introducing bounded retries:
```zig
tracked.attempts < 3;
tracked.retry_at = now + if (tracked.attempts <= 1) @as(f64, 0.25) else @as(f64, 0.5);
```
However, in `apps/zircon/src/services/language.zig` (`pollSyntax`), every highlight request still executes:
```zig
try host.start(self, cx, &.{ "highlight", grammar.wasm, grammar.name, grammar.highlights }, bytes, ...);
```
This spawns a fresh `zircon-extension-host` child process for every highlight pass.

### 5.1 Measurable Decomposition (Rejecting False Assumptions)
We must not assume that process startup is the sole or dominant latency contributor. A rigorous persistent worker step must measure and report each phase independently:

$$T_{\text{total}} = T_{\text{spawn}} + T_{\text{ipc\_send}} + T_{\text{wasm\_init}} + T_{\text{parse}} + T_{\text{ipc\_recv}} + T_{\text{ui\_ingest}}$$

1. **Process Spawn ($T_{\text{spawn}}$)**: Cost of `fork`/`posix_spawnp` on macOS, dynamic linking, and runtime startup.
2. **IPC Data Transfer ($T_{\text{ipc\_send}}$ / $T_{\text{ipc\_recv}}$)**: Writing the full 8 MiB snapshot buffer across stdin and reading JSON spans from stdout.
3. **WASM / Grammar Init ($T_{\text{wasm\_init}}$)**: Loading and instantiating the Tree-sitter WASM parser module and compiling highlight queries.
4. **Parsing Work ($T_{\text{parse}}$)**: Full AST construction from raw text versus incremental edit parsing (`ts_tree_edit`).
5. **UI Ingestion ($T_{\text{ui\_ingest}}$)**: Allocating and validating span arrays in `tab.editor.setHighlights`.

### 5.2 Persistent Worker Architecture
Rather than conflating grammar fixes with lifecycle performance, we recommend a dedicated persistent worker step structured as follows:

```
+------------------------------------------------------------------------+
|                          Zircon Main Process                           |
|                                                                        |
|   +----------------------------------------------------------------+   |
|   |                      SyntaxService Manager                     |   |
|   +----------------------------------------------------------------+   |
+-----------------------------------|------------------------------------+
                                    | Framed Duplex Pipe / Domain Socket
                                    v
+------------------------------------------------------------------------+
|                   Persistent Syntax Worker Process                     |
|                                                                        |
|  1. Retained WASM Engine & Tree-sitter Runtime                         |
|  2. Retained Grammars (WASM modules loaded once per language)          |
|  3. Retained Document Trees (reusable TSTree per active document)       |
|  4. Incremental Edits: apply ts_tree_edit() on small keystroke changes  |
+------------------------------------------------------------------------+
```

- **Protocol**: Framed JSON-RPC or binary TLV with versioned sequence numbers (`generation`, `document_id`, `revision`).
- **Cancellation & Freshness**: If typing generates revision $R+1$ while $R$ is being parsed, a cancellation token aborts $R$ immediately to prevent pipeline lag.
- **Measurable Benchmarking**: The benchmark suite must report microsecond timestamps for spawn, IPC, parse, and ingestion, proving where latency reductions actually occur.

---

## 6. Smallest Implementation Slice Ready to Code

To ensure safe, incremental delivery without destabilizing the working baseline, the editable diff work is partitioned into three ordered slices.

### Slice 1: Diff Layout Model & Read-Only Multi-Excerpt View (Ready to Code)
- **Goal**: Implement the structural view model, hunk navigation, and UI controls without introducing text mutations.
- **Files to Modify / Create**:
  - `packages/zircon_git/src/diff_layout.zig`: Data structures for `FileDiff`, `DiffHunk`, `DiffRow`, unified and split line pairing.
  - `apps/zircon/src/views/git_diff.zig`: Refactor rendering to consume `DiffLayout`.
  - Add below-tab diff toolbar with Unified/Split toggle, addition/deletion totals, Collapse All, and Next/Previous Hunk navigation.
  - Render rounded file headers with collapse chevrons and hoverable "Open File" actions.
- **Verification Gate**:
  - Headless UI tests verifying click-to-collapse, mode switching between unified and split, and bounds checking on toolbar buttons.

### Slice 2: Excerpt-to-Source Mapping & Single-File Editable Diff
- **Goal**: Enable editing in the new-side excerpt rows of a single changed file.
- **Files to Modify**:
  - `apps/zircon/src/views/git_diff.zig`: Implement `mapPointToSource` and coordinate hit-testing.
  - `apps/zircon/src/actions.zig`: Add `diffInput` handler routing keyboard and IME events to the backing `Workspace.DocumentId` via `Shell.applyOutcome`.
  - Connect debounced re-diffing on unsaved snapshot revisions while preserving cursor and scroll state.
- **Verification Gate**:
  - Portable unit tests asserting typing, backspace, multi-character paste, and undo inside an addition row, verifying that the source `Workspace.Record` updates correctly and deletions remain untouched.

### Slice 3: Multi-File Excerpt Transactions & Hunk Staging Integration
- **Goal**: Extend editing across multiple changed files and wire toolbar hunk staging.
- **Files to Modify**:
  - Manage multiple active `DocumentId`s in `DiffSession`.
  - Wire toolbar `Stage Hunk` and `Unstage Hunk` using `zircon_git.Repository.stagePatch`.
  - Enforce explicit separation between unsaved buffer state and index staging (GIT-04).
- **Verification Gate**:
  - Real repository tests staging individual hunks while retaining unsaved edits in neighboring hunks.

---

## 7. Summary of Review Findings

| Area | Status | Executed Evidence | Key Conclusion / Next Step |
| :--- | :--- | :--- | :--- |
| **Recovery Storage (`8ea2d7e`)** | **Verified Solid** (Storage Only) | `test-workspace`: 21/21 passed | Atomic write ordering, tombstones, and `DiskConflict` preservation are sound. Next step is UI lifecycle and background worker integration. |
| **Git UI Corrections (`5700514`)** | **Verified Solid** | `test-git`: 16/16 passed<br>`test-git-parsers`: 8/8 passed | Cursor metadata, popup reanchoring, and numstat badges verified. Diff view remains read-only. |
| **Grammar Retries (`c23490e`)** | **Verified Solid** (Retry Only) | 40/40 lifecycle runs pass | Bounded retry loop fixes crash loops. Next step is a separate, measurable persistent syntax worker. |
| **Editable Diff Architecture** | **Designed & Specified** | Specification grounded in `Workspace` & `Editor` | Adopt Candidate A (Per-Source Excerpt Projection). Implement Slice 1 (Layout & Controls) as the immediate next coding unit. |
