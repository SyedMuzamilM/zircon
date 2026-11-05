# Editor candidate B: persistent chunked documents

This is a design candidate, not an implementation claim. It uses Zircon UI's existing window, entity, custom-element, event and frame transaction contracts. Both architecture seats use the inherited model, so model diversity is reduced. No cross-family judge is configured.

## Usage first

```zig
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
const editor = @import("zircon_editor");
const ui = @import("zircon_ui");

var app = try ui.App.init(.{ .allocator = allocator });
defer app.deinit();
var project = try workspace.Workspace.init(allocator, io, root_path);
errdefer project.deinit();
const shell = try app.openWindow(Zircon, options, .{ .workspace = project });
try app.run();
```

The application owns project and tab policy. An editor view references a document entity and owns its own selections and viewport. Splitting an editor creates a second view of the same document, so edits and history are shared while caret positions and scrolling remain independent. No editor package imports AppKit, Objective-C, Metal, or CoreText directly.

## Package and module ownership

| Package | Owns | Dependencies |
| --- | --- | --- |
| `zircon_text` | UTF-8 document tree, revisioned edits, immutable snapshots, indexed line/UTF-16 conversion, history and literal search | Zig standard library |
| `zircon_workspace` | Stable document IDs, canonical paths, file identity, load/save conflict rules and project tree entries | `zircon_text`, standard library I/O |
| `zircon_editor` | Selections, movement/edit commands, composition session, viewport, syntax runs, custom canvas and input adapters | `zircon_text`, `zircon_ui` |
| `apps/zircon` | Workspace entity, pane/tab topology, file-tree presentation, palette, find/replace UI and dirty-close decisions | All packages |

A document model is independent of UI entities. The application wraps it in a document entity. `zircon_editor/document_entity.zig` can supply that adapter without making the portable text package depend on the framework.

Keep document storage, history, search, movement, lexical highlighting and painting in different files. One workspace file should not own disk persistence, edit application, key decoding and draw commands.

## Storage alternative

Use an immutable B+ tree of UTF-8 chunks, rather than a flat piece vector. Leaves contain up to 4 KiB of text and never split a UTF-8 code point. Internal nodes contain up to 16 children. Every node stores subtree byte count, UTF-16 code-unit count and LF count. Splits and joins copy only changed paths and at most the boundary chunks. Rebalance underfull nodes and merge small adjacent leaves so repeated one-character edits do not create one allocation per character forever.

A retained root is an immutable document snapshot. History retains roots and selection metadata instead of copied whole documents. A transaction builds a candidate root and history entry before swapping either into the document. Allocation failure releases that candidate and leaves text, history cursor, revision and selections unchanged.

Expected costs are O(log chunks) for locating a byte or line, O(log chunks + inserted bytes) for a localized edit, and O(log chunks + output bytes) for extracting a viewport. These are design bounds, not measured performance. A long single line can still require linear shaping work; its rendering budget needs its own policy.

This is more implementation work than a piece vector. It removes the eventual O(piece count) lookup cost and whole-index rebuild after small edits, and makes worker snapshots cheap. The first implementation must prove balancing, ownership and allocation-failure behavior before UI work. If that proof cannot be completed, choose the vector candidate and describe its actual limits rather than adding a half-correct tree.

### Snapshot ownership

The document's UI thread owns node reference counts. A task receives a snapshot retained before spawning, reads immutable text in `run`, and releases it only through UI-thread task cleanup after joining. Workers never clone, release or edit a snapshot. This avoids assuming every caller allocator is thread safe. Snapshot cloning/destruction enforce creator-thread affinity. Results carry document ID and revision; the UI rejects results for closed documents or superseded revisions.

Undo history has an explicit retained-byte budget and entry count. Exceeding it releases the oldest complete transaction. A saved-state marker identifies content history state, not the monotonically increasing edit revision. Undoing to saved content clears dirty state; saving while a newer edit exists does not incorrectly clear it.

## Concrete text interfaces

These are proposed signatures, to be reconciled with candidate A before implementation.

```zig
pub const Range = struct { start: usize, end: usize };
pub const Revision = u64;
pub const Edit = struct { range: Range, text: []const u8 };
pub const Point = struct { row: usize, byte_column: usize };
pub const Selection = struct { anchor: usize, head: usize };

pub const Document = struct {
    pub fn init(allocator: Allocator, utf8: []const u8) !Document;
    pub fn deinit(self: *Document) void;
    pub fn snapshot(self: *const Document) Snapshot;
    pub fn apply(self: *Document, expected: Revision, edits: []const Edit,
        before: []const Selection, after: []const Selection) !Revision;
    pub fn undo(self: *Document, selections: *SelectionList) !bool;
    pub fn redo(self: *Document, selections: *SelectionList) !bool;
    pub fn markSaved(self: *Document, saved_snapshot: Snapshot) void;
    pub fn isDirty(self: *const Document) bool;
};
pub const Snapshot = struct {
    pub fn clone(self: Snapshot) Snapshot;
    pub fn deinit(self: *Snapshot) void;
    pub fn revision(self: Snapshot) Revision;
    pub fn byteLen(self: Snapshot) usize;
    pub fn lineCount(self: Snapshot) usize;
    pub fn lineRange(self: Snapshot, row: usize) !Range;
    pub fn point(self: Snapshot, byte: usize) !Point;
    pub fn offset(self: Snapshot, point: Point) !usize;
    pub fn utf16Offset(self: Snapshot, byte: usize) !usize;
    pub fn copyRange(self: Snapshot, range: Range, allocator: Allocator) ![]u8;
    pub fn chunks(self: Snapshot, range: Range) !ChunkIterator;
    pub fn find(self: Snapshot, needle: []const u8, from: usize,
        direction: SearchDirection, case_sensitive: bool) !?Range;
};
```

`apply` validates UTF-8, code-point endpoints, a matching revision and sorted disjoint original-document ranges. It normalizes duplicate/overlapping cursors before editing, computes all transformed positions once, then applies changes as one transaction. It never commits the first cursor while another cursor can still fail. Search must match across chunk boundaries. Case-insensitive Unicode matching needs a named policy; ASCII folding must not be called full Unicode folding.

Retain CRLF bytes on disk and count lines by LF. Strip the preceding CR only for display. Record a preferred newline style for inserted newlines. Reject or explicitly handle non-UTF-8/binary files with an actionable UI error. Do not silently transcode or discard bytes.

## Workspace interfaces and disk safety

```zig
pub const DocumentId = struct { slot: u32, generation: u32 };
pub const DiskStamp = struct { /* file identity, size, mtime, digest */ };
pub fn open(self: *Workspace, path: []const u8) !DocumentId;
pub fn untitled(self: *Workspace, initial: []const u8) !DocumentId;
pub fn prepareSave(self: *Workspace, id: DocumentId) !SaveRequest;
pub fn finishSave(self: *Workspace, result: SaveResult) !void;
pub fn close(self: *Workspace, id: DocumentId, decision: CloseDecision) !bool;
```

Canonical paths deduplicate tabs; document IDs remain stable when display order changes. Save requests own the path, immutable snapshot, expected disk stamp and request ID. Write a sibling temporary file, preserve existing permissions, flush, verify the expected identity immediately before replacement, atomically rename, then report success. Failure must leave the original file usable. A changed disk stamp reports a conflict and does not overwrite silently. A preflight stamp check alone cannot eliminate a concurrent writer racing the final rename; document that limit or use platform coordination before promising conflict-free saves.

Finishing an older save marks only that snapshot as saved. Newer in-memory edits remain dirty. Save As changes document identity/path only after disk success. Closing a dirty document returns a decision request; Save, Discard and Cancel are explicit. No tab or window is destroyed while a save decision is pending.

Project discovery loads one expanded directory at a time, ignores `.git` internals and build caches by documented rules, and does not eagerly crawl entire disks. Search results identify document/path, revision, byte range and excerpt. Reload/refuse edits when a result's revision no longer matches.

## Editor state and commands

`EditorState` owns document entity identity, normalized selections, preferred visual columns, horizontal/vertical scroll, font settings, composition state and search session. `commands.zig` maps semantic commands to model operations. The keymap decodes keyboard chords; palette/menu items invoke those same commands. Command metadata includes title, shortcut and whether it is enabled.

Start with code-point-safe movement, then implement Unicode grapheme boundaries with pinned Unicode data before describing movement as fully Unicode aware. Word movement, visual columns, tab stops, indentation and CRLF boundaries need explicit tests. Multi-cursor edits use one document transaction and restore the complete selection set on undo. Views sharing a document transform their selections through each committed edit batch.

IME is one composition transaction. Retain its before snapshot and selections, apply provisional replacements without separate undo entries, and commit history once on final insert/unmark. Cancel restores the composition before state. A stale snapshot refuses the edit and requests a fresh frame. Do not append each marked-text update to ordinary typing history.

Syntax highlighting begins with deterministic language-specific lexers for Zig, Rust, JSON and Markdown. Keep lexical state per line and restart after the first changed line until state converges. This is lexical highlighting, not a parser, semantic tokens or language intelligence. Search match rectangles and diagnostics use separate paint layers.

## Custom canvas and bounded frame work

The entity's const render reads a document snapshot and copies only visible line slices and bounded surrounding IME text into the frame arena. Snapshot cleanup is registered with the frame if phase work must traverse it later. `requestLayout` captures the injected measurer; `prepaint` calculates selection rectangles, caret geometry and the text-input provider; `paint` emits background, current line, selections, highlighted text, composition underline, caret, gutter and scrollbar in that order.

Use `visibleRows` and overscan. A frame's retained work scales with visible text plus selected/IME context, not the total file. A huge active selection may need an expanded input snapshot; report that exceptional allocation instead of claiming a strict per-frame constant bound.

`TextSnapshot.base_byte` and `base_utf16` identify the surrounding text's document origin. Snapshot selection/marked ranges are local bytes; emitted `TextEdit.range` is absolute document bytes. Compute `base_utf16` through tree summaries. Native indices outside the published context are refused and refreshed. Pointer placement uses exact native line shaping through `Event.textMetrics`, including Unicode and tab expansion mapping. Source-byte-to-expanded-display mapping belongs to the editor, since tabs are document semantics.

The frame owns immutable hit geometry. Input handlers resolve the entity, use the event's committed bounds and layout metadata, then update selections or documents. They never retain a raw `*EditorState` in custom paint data. Native callbacks likewise never receive editor pointers.

## Application UI

Use a quiet dark editor palette, native system type for chrome and a readable monospaced font for source. The file tree and tab strip provide project context; the document gets the largest area. A slim status bar shows line/column, language, newline style and dirty/save errors. Do not fill toolbars with inactive placeholder actions.

A pane tree is `leaf(EditorViewId)` or `split(axis, ratio, left, right)`. Tabs reference views/documents by stable IDs. Dragging dividers changes ratios with min pane sizes. Switching tabs preserves each view's selection and viewport. File-tree activation opens or focuses a document. Quick Open searches actual project entries; the command palette filters actual registered commands. Find/Replace has editable query/replacement controls, next/previous, replace one/all and a visible result count. Escape closes overlays and restores focus to the originating view.

Framework reconciliation is required for safe window close: current `.close` dispatch marks the window closed before application handlers run. Add a cancellable close-request event and a framework close-confirmation operation, then test native titlebar close with dirty documents. Native file pickers also belong in Zircon UI's platform seam. CLI paths and an in-app path picker are a usable first delivery, but are not native file-dialog support.

## Verifiable implementation sequence

1. Implement document tree, snapshot lifecycle, batch transactions and history. Differential tests compare randomized Unicode edits with a flat reference string; allocation-failure tests cover every mutation and undo/redo. Check cached subtree metrics against rescans after split/merge sequences.
2. Implement workspace load/save in temporary directories. Test CRLF preservation, missing/invalid files, deduplication, permissions, disk conflicts, atomic write failure, stale save completion and dirty close decisions.
3. Implement editor movement/selections/composition/search as portable model tests. Verify multi-cursor overlap normalization, reverse selections, tabs, emoji, line edges and complete history restoration.
4. Attach one actual custom canvas to `App.openWindow`. Drive real native text, pointer drag, clipboard, composition selectors, scroll and resize. Assert document bytes and exported PNG pixels. Inspect the native result.
5. Add tabs, pane splits, project tree, palette and Find/Replace through the same commands and entities. Test focus restoration and close cancellation. Drive open, edit, split, find, replace, undo, save, reopen and close as one native journey.
6. Establish fixed release-build workloads for startup, idle memory, large-file scrolling and edit latency. Compare equal workloads with Zed only after both artifacts and measurement methods are recorded.

LSP diagnostics/completion/rename, Tree-sitter parsing, Git integration, a PTY terminal, debugging, collaboration, extensions and other operating systems are additional integrations. They must be implemented and exercised before claiming feature parity with Zed. This candidate supplies interfaces that can accommodate them; it does not count them as delivered.
