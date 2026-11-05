# Experience candidate A: UI-owned service entities

This candidate extends [editor-experience.md](../specification/editor-experience.md) and the existing [editor design](editor.md). It is a design, not an implementation claim. Both design seats inherit the same model, so model diversity is reduced. No different-family cross-judge is configured.

## Usage and ownership

One application-owned `Settings` entity, `ExtensionRegistry` entity and `Repository` entity serve all workspace/settings windows. A workspace owns `SearchSession` and per-language `LanguageSession` entities. Their public methods express user operations; workers receive owned request records and produce owned results. UI entities install those results only after checking the current request generation, document identity and document revision.

```zig
const settings = try app.createEntity(Settings, try Settings.load(a, io, config_path));
const extensions = try app.createEntity(ExtensionRegistry,
    try ExtensionRegistry.load(a, io, extension_directory));
const project = try app.createEntity(ProjectServices,
    try ProjectServices.init(a, io, root, settings, extensions));
_ = try app.openWindow(Shell, .{ .chrome = .integrated, .title = "Zircon" },
    try Shell.init(a, project));
```

The ordinary window owns view state. Service entities own domain state and process lifetimes. Render uses `Ui.watch` rather than copying service state into each window. Framework entities remain single-threaded. Long-lived worker transports never borrow an entity pointer.

## Package and module map

| Location | Responsibility | Imports |
| --- | --- | --- |
| `zircon_ui/platform/macos/window.zig` | Integrated chrome, traffic lights, native drag, parent-window behavior | System bindings, existing renderer |
| `zircon_ui/graphics/images.zig` | Immutable decoded image handles and scene lifetime | Standard library and native decoder adapter |
| `zircon_extensions` | Manifest validation, installation, contribution resolution | Standard library only |
| `zircon_git` | Real Git subprocesses and typed status/diff/history/blame | Standard library only |
| `zircon_search` | Snapshot/disk search, match groups, revisioned result identity | `zircon_text`, standard I/O |
| `zircon_lsp` | JSON-RPC transport, LSP state and document versions | Standard library, `zircon_text` coordinate helpers |
| `zircon_markdown` | Parsed blocks/inlines and source ranges | Standard library only |
| `apps/zircon/services/` | Entity adapters, jobs, settings persistence and refresh policy | Reusable packages and `zircon_ui` |
| `apps/zircon/views/` | Shell panels, settings, extension manager, search and diffs | Public UI/editor/service interfaces |

`zircon_text` continues to own document bytes/history. `zircon_editor` continues to own selections and canvas input. Git/search/extension packages do not open windows or call native code.

## Integrated native chrome and settings

Extend `WindowOptions` with `chrome: enum { standard, integrated }`, `parent: ?WindowHandle` and a documented `floating` option. macOS uses the existing titled/resizable/closable mask plus `NSWindowStyleMaskFullSizeContentView`, transparent titlebar and hidden native title. Retain native standard buttons, shadow, resize/fullscreen behavior and window semantics. The scene includes the top chrome region; reserve the traffic-light exclusion rectangle exposed by the platform so content never overlaps it. A normal settings window can be a native child ordered above its parent while retaining independent focus and resizing. Closing settings does not close the workspace.

Add `Ui.dragRegion(element)` metadata. Native `mouseDown` queries the committed logical region through the sink. A primary click in an enabled drag region, outside controls, invokes `performWindowDragWithEvent:`. Native resizing remains AppKit-owned. Double-click follows the system titlebar action. Do not make the whole custom view movable by background because tabs, text and panel dividers need distinct gestures.

```zig
pub const Settings = struct {
    revision: u64,
    values: Values,
    pub fn set(self: *Settings, key: Key, value: Value) !void;
    pub fn prepareSave(self: *const Settings) !SaveRequest;
    pub fn finishSave(self: *Settings, request_revision: u64, result: SaveResult) !void;
};
pub const Values = struct {
    theme_id: []const u8, icon_theme_id: []const u8,
    font_size: f32, line_height: f32, tab_width: u8,
    soft_wrap: bool, show_line_numbers: bool,
    git_gutters: bool, inline_blame: bool, reduced_motion: bool,
};
```

Only expose settings whose behavior is implemented. For example, omit a soft-wrap toggle until the editor has a visual-row index. Category/search results derive from one setting-descriptor table. All settings views and shell windows watch the shared entity. Persist through sibling temporary write/sync/rename; a failure retains the in-memory change and an unsaved-settings error. A stale save completion cannot mark newer values persisted. Theme changes must recolor chrome, source tokens and custom controls, not only the settings window.

Acceptance: real native screenshot includes traffic lights inside the top region; drag moves the window without selecting text; resizing/fullscreen still work; settings opens above the main window, changes font/theme in the main editor immediately, persists on reopen, and returns focus on close.

## Installable extensions

Use a data-contribution format first. Do not load arbitrary native libraries into the process. That is a real extension system for the requested theme/icon/language/server contributions, while an executable plugin host remains a separate future interface.

```json
{
  "schema_version": 1,
  "id": "org.example.oxide",
  "name": "Oxide",
  "version": "1.0.0",
  "contributes": {
    "themes": [{"id":"oxide-dark","path":"themes/dark.json"}],
    "icon_themes": [{"id":"oxide-icons","path":"icons/theme.json"}],
    "languages": [{"id":"zig","extensions":["zig"],"syntax":"languages/zig.json"}],
    "language_servers": [{"id":"zls","languages":["zig"],"command":"zls","args":[]}]
  }
}
```

A theme declares semantic UI colors and token-class colors, with missing values inheriting the built-in theme. An icon theme maps exact names/extensions/folders to bundled PNG assets or explicitly supported symbol names. A language definition declares file matching, keywords, line-comment delimiters, string delimiters and block-comment rules consumed by a generic lexer. Installed definitions alter the actual lexer selection; unsupported grammar constructs produce validation errors. Tree-sitter grammars need a later versioned contribution implementation rather than a silently ignored field.

```zig
pub const Registry = struct {
    pub fn discover(a: Allocator, io: Io, root: []const u8) !Registry;
    pub fn install(self: *Registry, io: Io, source_directory: []const u8) !ExtensionId;
    pub fn setEnabled(self: *Registry, id: ExtensionId, enabled: bool) !void;
    pub fn uninstall(self: *Registry, io: Io, id: ExtensionId) !void;
    pub fn resolve(self: *const Registry, settings: Selection) !ResolvedContributions;
};
```

Install validates schema/version/duplicate IDs, normalizes contribution paths and refuses paths escaping the package. Copy to a temporary managed directory then rename; failed installation leaves the old extension active. Enable/disable rebuilds a candidate resolved registry and swaps atomically. Consumers retain immutable contribution snapshots so unloading cannot invalidate a frame or language process. Uninstall first disables contributions, stops affected sessions, then removes managed files. A local catalog may contain actual bundled packages and configured catalog metadata. Show no fabricated marketplace counts or unimplemented network-install buttons.

Acceptance: install a fixture directory, select its theme/icon set/language, verify real rendered colors/icons/token changes, enable its fake language server, disable it and verify fallback. Invalid manifest/path traversal and failed copy preserve the old registry. Restart reads enabled state correctly.

## Git changes, history, gutters and inline blame

Use the system Git executable without a shell. Every argument is a separate argv value; path arguments follow `--` where supported. Parse machine-readable output, preserve NUL-delimited paths and treat process status/stderr as data. Do not parse display-oriented `git status` text.

```zig
pub const Repository = struct {
    pub fn discover(a: Allocator, io: Io, path: []const u8) !?Repository;
    pub fn status(self: *const Repository, a: Allocator, io: Io) !StatusSnapshot;
    pub fn diff(self: *const Repository, a: Allocator, io: Io, request: DiffRequest) !Diff;
    pub fn history(self: *const Repository, a: Allocator, io: Io, before: ?Oid, limit: usize) !HistoryPage;
    pub fn blame(self: *const Repository, a: Allocator, io: Io, path: []const u8, line: usize, contents: ?[]const u8) !Blame;
    pub fn mutate(self: *Repository, io: Io, operation: Mutation) !MutationResult;
};
pub const Mutation = union(enum) {
    stage_paths: []const []const u8,
    unstage_paths: []const []const u8,
    stage_patch: []const u8,
    unstage_patch: []const u8,
    commit: []const u8,
};
```

Status uses porcelain v2 `-z`; history uses an explicit NUL/record-separated format and `--no-decorate`. Diff uses `--no-ext-diff --no-color --unified=N` and an owned unified-diff parser with file/hunk/line records. Disable pager. Support unborn repositories and detached HEAD explicitly. Stage/unstage/commit serialize per repository service entity. Refresh status/history after successful mutation; on failure retain prior state and show stderr. No operation mutates an unrelated repository or silently discards working text.

For saved files, gutter jobs compare index content to working content. For unsaved files, compare the captured editor snapshot to the index blob using an internal line-diff implementation. Display added/modified/deleted markers only if the result's document revision still matches. A deleted range attaches to the adjacent surviving row with a documented boundary rule. Clicking a gutter marker opens an inline block keyed by file/hunk/revision. Clicking blame uses `git blame --line-porcelain --contents <owned-temp-file>` for the captured unsaved text, then renders real author, commit, date and summary. The inline block must occupy visual layout space, with pointer/caret row mapping adjusted through a visual-row model. An overlay covering text does not meet the inline-editor requirement.

Acceptance: temporary repository with two commits, staged/unstaged/untracked/renamed files, spaces and Unicode paths. Assert status records, hunk counts, gutter rows, blame identity, stage/unstage output and commit tree. Stage tests never touch the project's real index. A fake failed Git process and a stale revision result preserve UI/document state.

## Multi-buffer search

A `SearchSession` entity owns the active query, generation, ordered result groups and selected match. Starting a search captures open-document snapshots on the UI thread and a path-to-document map. The worker searches those snapshots and disk files, skipping disk versions of open files so unsaved text wins. Each group stores canonical path, optional document identity, captured revision or disk fingerprint, match byte ranges and copied context rows.

```zig
pub const Query = struct { text: []const u8, case_sensitive: bool = true, whole_word: bool = false };
pub const Match = struct { range: text.Range, line: usize };
pub const Group = struct { source: SourceStamp, matches: []Match, context: []ContextRow };
pub fn run(a: Allocator, io: Io, request: Request, cancel: *Cancellation) !Results;
```

Limit bytes/matches/context explicitly and expose truncation. Initial literal/whole-word search can be real without advertising regex. A later regex engine must define UTF-8/error behavior and cancellation. Group headers navigate to actual files and match positions. A multi-buffer view reuses editor canvases over captured source slices, with visible file headers and collapsed context gaps. Input maps excerpt positions back to the current document through its source stamp. If the stamp is stale, refresh/reveal the current document and refuse editing the old excerpt. Replace-all prepares per-document batches and reports disk conflicts; it cannot claim a cross-filesystem atomic transaction.

Acceptance: search two disk files and two unsaved buffers; prove unsaved precedence, no duplicate groups, exact byte ranges/context, cancellation, old-generation suppression, open-file navigation and stale-edit refusal. Native journey types into one search excerpt and independently checks that only its real document changed.

## Dragging and split topology

Replace the fixed primary/secondary fields with an indexed pane tree whose leaves own tab groups. A tab references one shared document and its independent Editor state. Drag state records stable tab/view IDs, source pane, pointer origin and current drop target. A movement threshold distinguishes activation from drag. Capture lasts until release/cancel. Paint insertion/split targets from committed geometry; commit tab transfer only on drop. Cancel leaves tab order and ownership unchanged.

Support reorder within one pane, move to another pane, edge-drop split and divider resizing. Never destroy a document while another view references it. Hidden tabs remain keyboard reachable. External file drops use the same open operation through an owned file-path event from the framework. Test drag/cancel with synthetic committed input, then real native pointer events and resize during a drag.

## Images and Markdown

Add immutable framework `Image` handles with CPU RGBA content and dimensions. Decode PNG/JPEG/GIF first-frame through direct Zig ImageIO/CoreGraphics bindings. The image store owns native decode objects and normalized pixel bytes; frame scenes retain image handles through cleanup. The Metal backend uploads textures lazily and holds per-submission texture leases. `Painter.drawImage` records destination/source rectangles, clip and opacity in painter order. Texture cache eviction cannot free a submitted texture. Native pixel tests prove channel order, alpha, orientation, clipping and draw ordering.

The editor workspace opens image files as image-viewer tabs rather than UTF-8 documents. Fit/actual-size/zoom use logical dimensions and scroll state. Markdown parses blocks/inlines into an owned tree with source byte ranges: headings, paragraphs, fenced code, lists, quotes, rules, links and images. A native custom element lays out and paints the tree using the framework text and image interfaces. Preserve source editing in a split/tab. Links expose an explicit open action; relative image paths resolve against the Markdown document. HTML is displayed literally or omitted under a documented policy, never executed through a webview.

Acceptance: real image tab with zoom, transparent PNG pixel checks, Markdown fixture with code/list/link/local-image and source navigation. Missing images show a recoverable error without abandoning the document. A native resize journey verifies reflow and scrolling.

## Language-server processes

`zircon_lsp` owns Content-Length framing, JSON parsing, request IDs, initialize/shutdown lifecycle, UTF-16 position conversion and versioned diagnostics/completions. A persistent transport owns the child process, stdin/out and worker queues. UI-owned `LanguageSession` sends typed commands and drains owned messages; it contains no blocking reads.

```zig
pub fn start(a: Allocator, io: Io, configuration: ServerConfig) !Client;
pub fn didOpen(self: *Client, uri: []const u8, language: []const u8, snapshot: Snapshot) !void;
pub fn didChange(self: *Client, uri: []const u8, snapshot: Snapshot) !void;
pub fn requestCompletion(self: *Client, uri: []const u8, version: i64, position: Position) !RequestId;
pub fn drain(self: *Client, a: Allocator) ![]Message;
pub fn stop(self: *Client) void;
```

Use full-document change notifications initially if incremental conversion is not yet proven; disclose their cost. Send initialize/initialized, didOpen/didChange/didClose and shutdown/exit correctly. Completion text edits validate the originating document version before application. Diagnostics use the server-reported version when available; unversioned diagnostics need a documented current-session policy. Restart clears stale diagnostics and fails pending requests visibly. Extension disable stops its server. A fake deterministic LSP subprocess is the primary protocol test, followed by an installed real server when available.

The current task executor only returns finite job completions. Persistent transport needs a thread-safe message queue plus native wake operation, so a reader can wake the UI without 120 Hz idle polling. Add that at the framework platform seam using an application-defined event or run-loop wake. The wake carries no entity pointer; the UI resolves generational recipients while draining. Shutdown closes transport pipes, terminates only its owned child if graceful exit fails, joins the reader, then releases queued messages.

## Implementation order and reconciliation

1. Finish the current editor regression checkpoint; preserve tests and commits.
2. Implement integrated chrome, native drag regions, child settings window and shared settings entity. Add theme consumers before exposing theme selection.
3. Implement extension manifests/install/resolve and real theme/icon/language changes. Add ImageIO/Metal image support and image tabs.
4. Implement Git package and service with temporary-repository tests; then changes/history/diff panels and revisioned gutters. Add visual-row blocks before inline blame.
5. Implement search package and grouped multi-buffer view over snapshots; prove editing/navigation mappings.
6. Implement pane-tree drag/drop and Markdown preview using existing images/text.
7. Implement LSP transport and extension-configured processes; prove diagnostics/completion against fake and real servers.
8. Run integrated native journeys, allocation/lifetime checks, startup/memory measurements and screenshot inspection. Update status per capability rather than counting screens as completed features.

This design concentrates state transitions and failure policy in UI-owned service entities. It costs additional entity adapters and requires explicit native wake support for persistent processes. An alternative worker-owned snapshot architecture can simplify background computation but needs more ownership-transfer, cancellation and stale-result machinery between every panel. Candidate A chooses one UI owner per service so several windows/panels see one coherent state, while retaining workers for all blocking I/O.
