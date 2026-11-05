# Editor candidate A: shared documents over a persistent rope

This is a design candidate, not an implementation claim. It uses the verified Zircon UI runtime described in [runtime.md](runtime.md). The editor is written from scratch and imports the independent `zircon_ui` package. Neither NanoUI nor GPUI becomes a dependency. Both design seats use the inherited model, so model diversity is reduced.

## Usage first

The application opens a workspace and a normal framework window. Editor code does not open a Metal device or send native messages.

```zig
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const editor = @import("zircon_editor");

var app = try ui.App.init(.{ .allocator = init.gpa });
defer app.deinit();
const project = try app.createEntity(workspace.Project,
    try workspace.Project.init(init.gpa, init.io, project_path));
const shell = try Shell.init(&app, project);
_ = try app.openWindow(Shell, .{ .title = "Zircon" }, shell);
try app.run();
```

`Shell` is application code. It composes file navigation, tabs, pane splits, search and the command palette from framework elements and `EditorView` entities. A workspace owns each document once. Two panes showing the same document retain independent cursor and scroll state.

## Grounding

`Ui.view` renders another const entity and records a dependency. `Ui.watch` reads through a scoped borrow and records the entity version. Custom elements receive a frame allocator, injected text metrics, final logical bounds and a Painter. Their phase storage belongs to the frame. An input handler resolves its mutable entity through a generated adapter and receives committed bounds, text metrics and clipboard operations. A handler calls `notify()` after a change.

Use those interfaces directly. A document snapshot retained by a custom element needs a frame cleanup hook or its own `deinit`. Do not retain an `App.read` pointer in a canvas. Layout or paint failure must preserve the previous frame, including its document snapshot and native input provider.

The framework's text snapshot now has an accepted bounded-text adjustment. `text`, `selection` and `marked` describe one UTF-8 excerpt. `base_byte` and `base_utf16` locate it in the document. Native edits carry absolute document byte ranges and the exact document revision. This keeps ordinary caret snapshots small. A selection covering a large range can require a large excerpt; that cost remains until the native query interface supports noncontiguous queries or retained document snapshots.

## Package ownership

| Package | Owns | Must not own |
| --- | --- | --- |
| `zircon_text` | UTF-8 storage, line indexing, immutable snapshots, edit transactions, history, literal search | UI entities, native objects, file paths, viewports |
| `zircon_workspace` | Open-document identities, paths, disk versions, loading/saving, project tree and close decisions | Caret positions, drawing, key bindings |
| `zircon_editor` | Selections, edit commands, composition sessions, viewport, syntax cache and editor custom element | Native windows, file saving policy, workspace tabs |
| `apps/zircon` | Window composition, tabs, pane split tree, command palette, search UI, settings and command dispatch | Storage internals, duplicate document text, native rendering |

`zircon_text` imports only the standard library. `zircon_workspace` imports text and standard I/O. `zircon_editor` imports text and UI. The app imports all four packages and joins their entity identities. If workspace entities need notification adapters, keep those in an app-facing module rather than making text storage depend on UI.

## Storage choice

A piece-table vector is the shorter first implementation. It keeps original bytes and an append buffer, then edits a vector of spans. Per-piece newline offsets avoid scanning unchanged bytes. A prefix index supports line lookup, but an insertion still shifts or rebuilds metadata for later pieces. Undo can store inverse spans instead of copying every descriptor vector. Its cost is proportional to the number of fragments after repeated edits, and rebuilding a flat line-start list makes typing proportional to document line count.

Choose a persistent balanced rope for candidate A. Leaves hold at most 4 KiB of UTF-8, split only at code point boundaries. Internal nodes cache byte length, newline count and balancing metadata. Replacing a range creates a new path and shares untouched subtrees. A snapshot retains one root. History retains roots rather than whole-document byte copies. Searches stream leaves; visible-line extraction never flattens the document.

This choice costs more implementation and allocation-lifetime proof. It earns that complexity because snapshots are needed simultaneously by frames, undo, search workers and saves. The same representation solves those uses instead of adding separate copies. The alternative vector representation remains a reasonable candidate if the first delivery explicitly accepts linear fragment metadata updates. Neither representation establishes a speed or memory advantage over Zed without measurements.

Use immutable leaf storage and reference counts confined to the document/UI owner initially. A worker must receive an explicitly thread-safe snapshot ownership wrapper or an owned extracted byte buffer. Do not pass UI-thread reference counts to workers and then claim snapshots are thread-safe.

## Text interface

These are the public operations required by callers. The rope, nodes and history entries stay private.

```zig
pub const Range = struct { start: usize, end: usize }; // UTF-8 bytes, half-open
pub const Point = struct { line: usize, byte_column: usize };
pub const Edit = struct { range: Range, text: []const u8 };
pub const Affinity = enum { before, after };
pub const Revision = u64; // increases on edit, undo and redo; never rewinds
pub const StateId = u64;  // identifies a retained content state for dirty tracking

pub const Document = struct {
    pub fn init(a: Allocator, bytes: []const u8, options: Options) !Document;
    pub fn deinit(self: *Document) void;
    pub fn snapshot(self: *const Document) Snapshot;
    pub fn apply(self: *Document, expected: Revision,
        edits: []const Edit, group: GroupId) !Change;
    pub fn undo(self: *Document) !?Change;
    pub fn redo(self: *Document) !?Change;
};

pub const Snapshot = struct {
    pub fn deinit(self: *Snapshot) void;
    pub fn revision(self: Snapshot) Revision;
    pub fn stateId(self: Snapshot) StateId;
    pub fn byteLen(self: Snapshot) usize;
    pub fn lineCount(self: Snapshot) usize;
    pub fn lineRange(self: Snapshot, line: usize) !Range;
    pub fn pointAt(self: Snapshot, byte: usize) !Point;
    pub fn offsetAt(self: Snapshot, point: Point) !usize;
    pub fn copy(self: Snapshot, a: Allocator, range: Range) ![]u8;
    pub fn chunks(self: Snapshot, range: Range) !ChunkIterator;
    pub fn find(self: Snapshot, needle: []const u8,
        from: usize, direction: Direction, options: SearchOptions) !?Range;
};

pub const Change = struct {
    before: Revision, after: Revision, state: StateId,
    pub fn map(self: *const Change, offset: usize, affinity: Affinity) usize;
    pub fn deinit(self: *Change) void;
};
```

`apply` accepts sorted nonoverlapping ranges in the old revision. Validate UTF-8 and every range before building a root. Duplicate insertion positions are normalized by the editor before the call. Allocate the new root, change map and history entry before swapping document state. Any failure leaves text, revision and history unchanged. Empty edits do not add history. After undo, a new edit releases the redo branch. Revision exhaustion returns an error before mutation.

A line count includes the final empty line after a trailing newline. Preserve original bytes and CRLF endings. A display line excludes its ending; a line range operation must say whether it returns content or content plus ending. Define both explicitly if needed. Byte columns never pretend to be user-visible columns. Grapheme movement belongs to a Unicode cursor helper and must be tested with combining marks and emoji sequences.

History groups coalesce normal typing. Paste, multi-cursor edits, replace-all and a completed IME composition are each one group. Bound retained history by a documented byte/node estimate; pruning releases roots and leaves. The estimate is not a process-memory cap.

## Workspace interface and disk safety

```zig
pub const DocumentId = struct { slot: u32, generation: u32 };
pub const CloseDecision = union(enum) { ready, needs_save: DocumentId };
pub const SaveResult = struct { state: text.StateId, disk: DiskVersion };

pub const Project = struct {
    pub fn init(a: Allocator, io: std.Io, root: []const u8) !Project;
    pub fn deinit(self: *Project) void;
    pub fn open(self: *Project, path: []const u8) !DocumentId;
    pub fn untitled(self: *Project) !DocumentId;
    pub fn snapshot(self: *const Project, id: DocumentId) !text.Snapshot;
    pub fn edit(self: *Project, id: DocumentId, expected: text.Revision,
        edits: []const text.Edit, group: text.GroupId) !text.Change;
    pub fn undo(self: *Project, id: DocumentId) !?text.Change;
    pub fn redo(self: *Project, id: DocumentId) !?text.Change;
    pub fn save(self: *Project, id: DocumentId, path: ?[]const u8) !SaveResult;
    pub fn requestClose(self: *Project, id: DocumentId) !CloseDecision;
    pub fn close(self: *Project, id: DocumentId, decision: CloseAuthorization) !void;
    pub fn children(self: *Project, a: Allocator, directory: []const u8) ![]Entry;
};
```

The edit/history operations resolve the document identity and update workspace dirty/close state as one operation. They hide document allocation and stale-ID checks; callers do not retain a document pointer from a project callback. Paths and labels returned for frames are copied into frame storage. A canonical file identity deduplicates opening the same file twice. Directory traversal is lazy; opening one folder does not scan the entire project. Errors stay visible in the shell and do not close an existing document.

A save captures an immutable content state, writes a uniquely named temporary sibling, flushes it and atomically renames it. Failed write or rename leaves the previous file intact and retains the dirty state. Preserve file permissions when replacing an existing file. Record the saved state ID, not the revision current when the save callback returns. If editing continued during a save, the current document remains dirty. Detect changed disk identity/version before overwriting and require an explicit conflict decision. Tests must cover symlinks, permission errors and cancellation rather than silently assuming rename handles every case.

The shell shows Save, Discard and Cancel for dirty close. Cancel preserves the tab and document. Closing a pane is separate from closing the shared document. Native window close needs a framework close-request/default-prevention contract before the shell can protect all dirty documents. The current immediate `.close` handling is a concrete framework gap to reconcile.

## Editor state and commands

`EditorView` owns a `DocumentId`, a sorted `SelectionSet`, primary selection, scroll state, preferred horizontal caret coordinate, composition state and viewport options. It receives document access through an app entity adapter. The text document remains the only writer of bytes.

```zig
pub const Selection = struct { anchor: usize, head: usize };
pub const Command = union(enum) {
    insert: []const u8, delete_backward, delete_forward,
    move: Move, select_all, add_cursor: usize,
    undo, redo, find_next: SearchQuery, replace: Replacement,
};
pub fn execute(state: *EditorState, document: *text.Document,
    command: Command, metrics: Metrics) !EditOutcome;
```

The editor normalizes selections into ordered nonoverlapping ranges before editing. A batch insert replaces all selected ranges in one text transaction. It computes the new carets from the returned change map. Map inactive panes' selections through the same change map. Each view retains history selection metadata keyed by content state ID, so undo restores its known selection when available and otherwise maps the current selection. No view keeps an independent copy of document text.

IME composition uses the primary selection only and suspends multi-cursor duplication until commitment. Keep the pre-composition snapshot and selection. Updating marked text replaces the prior marked range without pushing a separate undo group. Commit creates one history group; cancel restores the pre-composition state. Refuse stale native revisions and request a fresh frame. A refusal must not terminate the application event loop.

Navigation covers code point and word movement first, with grapheme boundaries required before claiming editor-grade Unicode movement. Home/end, page movement, indentation, newline indentation, line duplication, line selection and matching-bracket navigation are semantic commands. OS shortcuts and command-palette entries dispatch these commands through one registry. Command IDs, labels, shortcuts and handlers come from one table.

## Canvas and rendering

The editor custom element receives a frame-owned `RenderSnapshot`, never a borrowed mutable document. It owns a retained text snapshot and copies only visible lines, syntax spans, selections and the bounded native input excerpt. Its `deinit` releases the retained snapshot.

`requestLayout` returns the available viewport and stores injected text metrics. `prepaint` calculates visible logical lines plus overscan, glyph-based caret and selection geometry, the primary caret rectangle, horizontal extent and the focused native text snapshot. `paint` records gutter, active line, search hits, selection rectangles, syntax runs, marked-text underline and carets in that order. Clip document content separately from the gutter.

A fixed line height gives direct vertical row lookup for the first nonwrapping version. Horizontal coordinates use the framework's actual CoreText caret/index functions, including fallback fonts. Tabs need explicit visual tab-stop mapping between document byte offsets and shaped display bytes. Never draw literal tabs and assume every shaper uses the same stop width. Soft wrap needs a separate visual-row index; it cannot be added by relabeling logical lines.

The syntax module is a stateful lexer cache keyed by document revision and line start state. It stores token classifications, not colors. Themes map classifications to colors. Start with Zig plus plain text and add languages only with lexer tests. Relex until the outgoing lexical state converges after an edit. Background syntax/search results include document identity and revision and are discarded when stale.

The shell uses normal framework layout for a narrow project sidebar, tab strip, editor pane tree and status bar. Panes embed EditorView entities. Menus and the command palette use the same typed commands. A dark slate document area, quieter blue-gray chrome and a restrained blue focus/selection color support long reading sessions. System UI text and a monospace code font provide distinct roles. No buttons advertise unimplemented actions.

## Delivery sequence and proof

1. Implement text storage and transaction/history behavior. Compare deterministic random edits against a flat UTF-8 reference. Check allocation failures, line mappings, retained snapshots, undo branches and multi-edit change maps.
2. Implement workspace open/save/tree and close decisions with temporary-directory tests. Prove a failed save retains the old file and that late save completion does not mark newer edits clean.
3. Implement pure editor commands and selection mapping. Test multi-cursor normalization, Unicode movement, tabs, history selection restoration and composition grouping.
4. Render one real file through the public framework path. Drive native click, drag selection, typing, Unicode composition, scrolling, undo, search and save. Verify disk bytes independently of the UI.
5. Add tabs, split panes, project navigation, palette and replace UI. Test two panes sharing one document and dirty-close Cancel/Discard/Save paths.
6. Measure fixed workloads after functional checks. Record release binary size, startup, idle/typing memory, visible-line extraction and a large-file edit workload with exact files and configurations. Compare Zed only with equivalent workloads and disclosure of feature differences.

LSP completion/diagnostics, Tree-sitter parsing, Git status/diff, terminal PTY emulation, debugging, extensions, collaboration and distribution signing are separate implemented integrations, not decorative shell tabs. A working editing core is not evidence that those exist. Native accessibility and full document-point IME queries remain framework requirements before claiming production parity.

## Red-flag screening

One document owns bytes and history. Views own presentation and selections. The workspace owns disk state. Internal rope nodes never appear in public types. The editor's native integration goes through the framework snapshot/input interface. Save is one workspace operation that hides temp files and conflict checks. One command registry derives shortcuts and palette entries. There is no second immediate-mode editor renderer or separate test-only input model.

The main risk is rope implementation complexity. Keep balancing and node ownership in one private module and test them through document behavior plus internal invariant checks. If this candidate cannot pass allocation-failure and retained-snapshot tests, use the vector candidate with explicit limits instead of publishing an unsafe persistent tree.
