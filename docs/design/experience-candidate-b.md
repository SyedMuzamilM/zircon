# Experience candidate B: snapshot jobs and protocol-owned packages

This candidate implements the [expanded experience requirements](../specification/editor-experience.md) on the existing independent Zig framework. It is a design, not an implementation claim. Both seats use the inherited model, so model diversity is reduced. No different-family judge is configured.

## Usage and ownership

A workspace window owns editor/document presentation. Background packages receive immutable owned requests and return immutable owned results. They do not become UI entities and never borrow the shell. One application-owned host schedules work, accepts completions and asks ordinary entity updates to install them.

```zig
const ticket = try services.submit(.{ .git_status = .{
    .workspace = project.identity,
    .root = try allocator.dupe(u8, project.root_path),
    .generation = git_view.request_generation,
} });
// App.step drains owned completions on the UI thread.
// Install only if workspace, request generation and source revision still match.
```

`Services` is an app implementation detail. Git, search, extensions and language protocols expose independent interfaces that can be exercised without Zircon UI. This differs from a design where every backend becomes an entity with cross-entity observations. The cost is explicit result installation; the benefit is that protocol parsers, cancellation and process lifetimes do not depend on UI borrow rules.

## Package map

| Package/module | Owns | Interface used by the app |
| --- | --- | --- |
| `zircon_ui` | Native chrome, window relationships, image assets, drawing and pointer delivery | WindowOptions, window operations, Painter.image |
| `zircon_config` | Settings schema, atomic persistence, migrations and effective values | Store.load/update/snapshot |
| `zircon_extensions` | Installed manifests, contribution validation, activation snapshots | Registry.install/setEnabled/remove/snapshot |
| `zircon_git` | Git process commands, parsers, repository result models | Repository.query/mutate/blame |
| `zircon_search` | Buffer/disk input merge, matching and grouped results | search(Request, Cancellation) |
| `zircon_language` | Stdio JSON-RPC, server lifecycle and document versions | Session.open/change/request/poll/close |
| `zircon_markdown` | Markdown blocks/inlines, source ranges and layout data | parse(snapshot), blocks |
| `apps/zircon/services` | Tickets, per-repository mutation ordering and stale-result checks | submit/cancel/drain |

Use package roots only. Raw porcelain, JSON-RPC objects and native image pointers stay private. Settings and extension snapshots have immutable revision identities and explicit cleanup, so frames retain a version without copying the registry every render.

## Integrated chrome and separate settings

Add `WindowOptions.chrome = .system | .integrated`, plus optional parent handle and `.normal | .floating` level. The default remains system chrome for existing clients. Integrated macOS windows retain titled/closable/resizable/fullscreen styles and add full-size content view. Hide the title text and make the titlebar transparent. Keep real native traffic-light controls. Expose their reserved logical rectangle to layout, rather than hard-coding its origin in every application view.

The framework owns a drag-region operation attached to a designated header element. On an unconsumed primary down it calls native `performWindowDragWithEvent:` with the original event, or a private equivalent that retains the event through dispatch. It must not make the entire content view movable by background, since editor selection and tabs also receive pointer events. Double-clicking the designated header uses the platform zoom policy. Native input metadata stays inside the adapter.

A settings window is another `App.openWindow(SettingsView, ...)`, parented above the workspace. It references a shared application-owned settings model, not a pointer to Shell. `Ui.watch` makes the settings view and editor depend on the effective settings revision. Closing settings releases its window scope while leaving the shared settings alive. Reopening reuses the existing settings handle when live. A platform raise/focus operation brings it forward and preserves the previous workspace focus target.

`zircon_config.Store.update(Patch)!Update` validates and writes a candidate JSON file with sibling-temp sync/rename before installing its persisted snapshot. On disk failure retain the previous effective persisted configuration and show the error. Themes and font sizes can optionally have a separately labelled preview transaction, reverted by Cancel. Versioned schema migration retains the original file as a recovery copy. Unknown keys survive load/save so future versions do not silently discard them.

Settings pages come from one descriptor list of key, category, label, help, type, default and range. Derive category navigation, search and JSON editing from it. Initial real controls should cover theme/icon theme, UI/editor font size, tab width, line numbers, reduced motion, Markdown preview behavior, language server enablement and Git gutter visibility. Do not show toggles without behavior.

## Contribution extensions

Install a local extension directory with a versioned `extension.json` plus relative assets. Registry install copies into a temporary directory under the configured extension home, validates all contributions, then renames the directory and atomically updates enabled state. Uninstall disables first and removes only that installed extension directory after its readers/processes release references. Validate IDs, schema versions, duplicate contribution IDs, path traversal and size limits. An invalid extension leaves the previous registry active.

```zig
pub const Registry = struct {
    pub fn init(a: Allocator, io: Io, home: []const u8) !Registry;
    pub fn install(self: *Registry, directory: []const u8) !ExtensionId;
    pub fn setEnabled(self: *Registry, id: ExtensionId, enabled: bool) !void;
    pub fn remove(self: *Registry, id: ExtensionId) !void;
    pub fn snapshot(self: *const Registry) RegistrySnapshot;
};
```

The initial format contributes named color-token maps, file-name/extension icon mappings, language associations and declarative lexical rules, plus language-server executable/argv/options. Lexical profiles support tested keywords, line/block comment delimiters, quoted strings, escapes and numeric rules. They change the editor lexer directly. This is a real constrained contribution system, not an arbitrary executable extension host or compatibility with Zed/WASM extensions. Describe that capability boundary in the extension manager.

Built-in contributions use the same format. The manager's Available tab lists bundled or configured local catalog entries; Installed lists actual installed manifests and validation errors. Install Dev Extension opens a real directory path/picker. Do not invent download counts or remote catalogs. Disabling a theme/icon provider selects a deterministic built-in fallback. Disabling a language provider invalidates its lexical cache and shuts down its configured server sessions.

## Git changes, history, gutters and blame

`zircon_git.Repository` stores a canonical root and I/O dependency. Queries return owned models; worker jobs have finite output limits and deadlines. Mutations are serialized per repository by Services, while independent queries can overlap. Every result carries repository identity and request generation. Commands use argv arrays, never interpolated shell text.

```zig
pub const Query = union(enum) { status, history: HistoryRequest,
    diff: DiffRequest, file_at: FileRevision, blame: BlameRequest };
pub const Mutation = union(enum) { stage: []const Path,
    unstage: []const Path, commit: CommitRequest };
pub fn query(repo: Repository, a: Allocator, request: Query,
    cancel: *Cancellation) !Result;
pub fn mutate(repo: Repository, a: Allocator, request: Mutation,
    cancel: *Cancellation) !MutationResult;
```

Parse `git status --porcelain=v2 --branch -z` for tracked, renamed and untracked paths. Preserve paths containing tabs/newlines through NUL-delimited protocols and explicit byte lengths. Working/staged diff requests use explicit source kinds. History parses a fixed machine format with full object IDs, parents, author, timestamp and subject; opening a commit uses actual file content and diff, not the current file labelled with an old commit.

Stage and unstage operate on the on-disk worktree/index through `git add -- <paths>` and `git restore --staged -- <paths>`, with an unborn-HEAD fallback that only removes requested index entries. Commit takes the exact user message over stdin or a private message file, honors hooks and displays stderr/exit failure. It never auto-commits unrelated working changes. Refresh status/history only after completion. A failed mutation retains the prior displayed result and shows an error with Refresh available.

Editor gutters compare a captured current buffer snapshot with an immutable HEAD/index baseline. Return line intervals classified added/modified/deleted, keyed by document revision and baseline object ID. Deleted lines receive an anchor at the following surviving line or EOF. The app installs only matching results. Unsaved buffer changes therefore appear in gutters before Save. Git-panel Stage acts on disk bytes; show an unsaved badge when its buffer differs, so staging does not silently save text.

Inline blame uses `git blame --line-porcelain --contents - -- <path>` with the captured buffer as stdin where supported. Uncommitted lines have an explicit uncommitted identity. A gutter click requests the selected logical line; the editor paints an inline card with author, time, summary and commit navigation. The result carries the document revision. Editing before delivery invalidates the card. No blame information is inferred from line number alone after edits.

## Multi-buffer search

```zig
pub const Request = struct { generation: u64, query: Query,
    open_buffers: []OwnedBufferSnapshot, files: []OwnedPath };
pub const FileMatches = struct { source: SourceIdentity,
    matches: []Match, excerpts: []Excerpt };
pub fn search(a: Allocator, io: Io, request: Request,
    cancellation: *Cancellation) !SearchResult;
```

Canonical open-buffer paths override disk files, including dirty buffers. Untitled buffers receive stable document identities and are also searched. Snapshot references are retained before spawning and released on the UI thread after worker join, matching the existing text package contract. Workers only read them. Disk sources carry a fingerprint; open sources carry document identity/revision. Results are grouped by source, include source ranges and line context, and have explicit truncation/error counts.

Literal case-sensitive search comes first, with whole-word and ASCII-insensitive behavior clearly named. Regex requires an actual tested engine before displaying its toggle. Query changes cancel/supersede older generations. Activation revalidates the source, opens the actual buffer and selects the range. For stale results, refresh the group rather than editing an obsolete offset.

The results tab is a multi-buffer view of excerpts with file headers, match count, next/previous and Open File. Excerpts map visual rows to source identities/ranges. If editable excerpts are included, edits route to the underlying document as revisioned edits and update every peer view. Do not duplicate document storage into a result-only buffer and lose changes when it closes. Begin with openable read-only excerpts, then implement routed editing before claiming editable multi-buffer results.

## Dragging and pane topology

Replace the single optional secondary pane with a small binary pane tree whose leaves contain tab stacks. Editor/document IDs remain stable when tabs move. A pointer-captured drag session stores source pane/tab ID, start point, current point and prospective drop target. Crossing a logical distance threshold begins dragging; a click still activates the tab. Paint a tab ghost and explicit insertion/split preview.

Drop zones select tab insertion or left/right/top/bottom split. Allocate the candidate pane topology and view state before removing the source tab. Failure leaves the original pane tree intact. Dropping outside valid regions cancels. Split-divider capture updates ratios with minimum pane sizes; resizing clamps ratios without destroying panes. Native external file drops enter through a framework-owned copied path-list event and use the same open-file command.

## Images and Markdown

Add framework `Image` assets with generational identities and immutable decoded RGBA storage. The macOS decoder uses direct Zig ImageIO/CoreGraphics calls, validates dimension/byte-count limits and applies orientation. The renderer owns a texture cache keyed by image identity, uploads once, and leases textures until GPU completion. `Painter.image(image, bounds, fit, opacity)` records an ordered image command; frames retain an asset reference through cleanup. It must not copy multi-megabyte pixels into every frame or expose native textures to the editor.

Image tabs provide actual dimensions, fit/actual-size and zoom/pan, with decode errors displayed without losing the prior tab. Test PNG/JPEG alpha/orientation and unsupported/corrupt files. File icons can initially use small raster assets or a supported vector subset; do not silently treat SVG paths as a working SVG renderer.

`zircon_markdown` parses headings, paragraphs, emphasis, links, lists, blockquotes, fenced code, tables and image references into source-ranged blocks. Layout and paint use the same text/image framework; Markdown does not require a webview. Preview is another view of the shared document, with source/preview or side-by-side mode and scroll anchors by source range. Resolve local images relative to the document and invalidate by asset identity. Links activate through an explicit framework URL operation. Initial remote image loading needs an actual network/cache policy; local-only support must be labelled until then.

## Language-server protocol

`zircon_language.Session` owns one long-lived stdio server process per server/workspace configuration. The app sends immutable document snapshots and requests; the session emits typed diagnostics/completions/errors with URI and version. JSON-RPC framing, URI escaping, UTF-16 coordinates and server capability negotiation remain inside the package.

Zig0.17.1 has `std.process.spawn(io, .{ .argv=..., .cwd=..., .stdin=.pipe, .stdout=.pipe, .stderr=.pipe })`; the returned Child owns the pipe files. Use it for LSP, with dedicated readers for stdout and stderr and a serialized writer. `std.process.run` is suitable for finite Git queries, with stdout/stderr limits and timeout, but not a live LSP session. A generic process module hides these two policies. Existing cooperative task cancellation alone cannot interrupt a blocked pipe read; Session.close must signal its owner, close/kill the child through synchronized process ownership, join readers and then release buffers.

Start with initialize/initialized, didOpen/full didChange/didClose, publishDiagnostics, completion/resolve and shutdown/exit. Each document change carries its actual monotonically increasing protocol version. Completion text edits are converted against the exact requested snapshot; apply only when the document revision still matches, as one atomic batch. Stale completions disappear or refresh. Diagnostics likewise retain version provenance. Unknown server requests receive correct JSON-RPC errors; logs go to bounded stderr storage, never the protocol stream.

A fake fixture server proves framing, out-of-order responses, Unicode ranges, malformed messages, cancellation and teardown. Then exercise one real installed server, preferably ZLS for this Zig repository, with a known diagnostic and completion that change after editing. Missing executables produce an actionable state, not a permanently successful Connected badge.

## Verifiable implementation order

1. Integrated native chrome and settings window relationship. Drive header drag, native controls, resize/fullscreen, settings open/raise/close and workspace focus return.
2. Configuration and local extension registry. Install a real sample theme/icon/language contribution, toggle it, restart, and verify changed pixels/tokens/settings persistence. Invalid manifests preserve the previous snapshot.
3. Git/search packages with portable temporary-repository/file tests, then app changes/history/gutters/blame and grouped search results. Cover renames, spaces, untracked/deleted files, unsaved buffers and stale jobs.
4. Pane-tree dragging, native file drops and live source-range navigation. Verify failed drops and minimum-size behavior.
5. Image decode/texture rendering, then Markdown preview over shared snapshots. Verify actual decoded/rendered pixels and edit-to-preview updates.
6. LSP fixture/server tests and UI diagnostics/completion through configured contributions. Measure idle process/resource cleanup after closing workspaces and disabling providers.

Each stage is delivered only after its own behavior works. Existing editor tests remain required throughout. A local contribution registry is not a remote marketplace, a lexical profile is not a parser, and passing protocol fixtures is not proof of every language server. These distinctions belong in status and extension capability metadata.
