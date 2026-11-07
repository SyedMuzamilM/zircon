# Zircon Workspace

A portable file and document model for the Zircon editor. It depends on `zircon_text` and Zig's standard I/O. It does not depend on a UI framework or native objects.

```zig
const workspace = @import("zircon_workspace");
var project = try workspace.Workspace.init(allocator, io, project_path);
defer project.deinit();
const id = try project.open("src/main.zig");
const record = try project.get(id);
var change = try record.doc.apply(record.doc.revision(), &.{
    .{ .range = .{ .start = 0, .end = 0 }, .text = "// Edited\n" },
}, 0);
defer change.deinit();
try project.save(id, null);
```

## Document ownership

`DocumentId` contains workspace identity, slot and generation. A copied ID owns nothing. Closing releases the document and retires that generation. Another workspace cannot resolve the ID. `get` and `getConst` return heap-stable records; use these pointers within the owning model operation and do not retain them past close or workspace destruction.

A record owns `doc`, an optional canonical `path`, disk fingerprint and optional `saved_state`. `title()` returns a borrowed basename or untitled label. `dirty()` compares content-state identities, so undoing to the saved content clears the dirty flag. Empty new documents start clean. Nonempty untitled content remains dirty until saved.

`open` resolves paths against the canonical workspace root and deduplicates canonical names, including symlink aliases. It preserves UTF-8 bytes and CRLF endings exactly. Invalid UTF-8 and embedded-NUL binary files return explicit errors. Files larger than64 MiB are refused before loading. The workspace root is a path base, not a filesystem sandbox.

## Committed change events

`Workspace.apply(id, expected_revision, edits, group, origin)` returns one owned `DocumentChange`. It transfers the successful text transaction's mappings without allocating after commit. Call `deinit` once or transfer the event into `ChangeLog.push`. `DocumentChange.take` moves an existing `text.Change`; do not deinitialize that source afterward.

`ChangeLog` owns at most 128 events and 1 MiB of mapping buffers. `push` cannot fail, evicts older entries, and releases events that exceed the byte limit. `get(index)` returns a borrowed event until the next mutation. `clear` releases all entries. Missing history requires snapshot resynchronization. Undo/redo reset events use empty mappings and monotonic before/after revisions.

## Saving and closing

`save(id, optional_save_as_path)` captures an immutable text snapshot. It prepares the destination path and file data before publishing, creates an atomic sibling file, writes and syncs its data, preserves an existing file's POSIX permissions, checks the disk fingerprint again and publishes atomically. On successful publication, changing record path and saved-state metadata requires no further allocation.

Fingerprints include inode, size, modification time, permissions and SHA-256 content. Fingerprinting streams through a32 KiB buffer. Saving currently flattens the captured document once, up to64 MiB. New destinations use no-clobber atomic publication. Save As to a different existing file returns `PathAlreadyExists`; overwriting another open document returns `DocumentAlreadyOpen`. An untitled save without a path returns `SavePathRequired`.

An existing file changed since loading or the previous save returns `DiskConflict`. Failure before publication leaves the original file and saved marker unchanged. Conflict checks are optimistic; an external writer can race the final check and rename. File data is synced before publication, but this module does not promise power-loss durable directory updates. It preserves permission bits, not ownership, extended attributes or all platform metadata.

`close(id, .if_clean)` refuses dirty documents with `UnsavedChanges`. `.cancel` keeps the document. `.discard` releases it. `.save` saves dirty content first and closes only after success. The application supplies Save/Discard/Cancel UI and handles Save As when needed.

## Recovery storage

`recovery.Store.init(allocator, io, recovery_home, project_root)` locks the newest available session for that root, or creates a new session. A live window's session remains locked. `initFresh` always creates a separate session and leaves abandoned sessions available for later restoration. Use `initFresh` when replacing a discarded session; resuming another window's backup and immediately publishing unrelated documents would overwrite that backup.

`publish` writes immutable document content before atomically replacing the session index. Unchanged contents can reuse `ContentRef`. `load` validates hashes, bounds and metadata, retains corrupt content for salvage, and returns available documents with a warning count. `exclude` writes a document tombstone, while `discard` excludes a whole session. Callers serialize these operations and keep the store lock alive until all writers finish.

`Workspace.restore` creates a new runtime document identity from checkpoint bytes. Passing the original `DiskStamp` preserves later save-conflict detection. Restoring a checkpoint does not write the source file. Storage uses file sync and atomic publication, without promising power-loss durability for directory changes. The native integration and its checkpoint policy are documented in the [editor guide](../../docs/editor-guide.md#recovery).

## Project navigation

`children(directory, allocator)` lists one directory only, with directories sorted before files and names sorted without ASCII case. Entries own copied `name` and absolute `path`; call `deinitEntries(entries, allocator)`. Symlinks to regular files/directories are listed, and broken links are skipped. Expanding a symlink directory is the application's explicit operation; the package does not recursively crawl trees.

Listings omit `.git`, `.zig-cache`, `.tools`, `zig-out`, `node_modules` and `.DS_Store`. Other hidden files remain visible. Filesystem paths/names retain their original bytes; a UI displaying an unusual non-UTF-8 filename must provide an escaped display label.

I/O is synchronous and workspace mutation is single-owner. Application adapters can run owned snapshot saves in workers, but this package does not make mutable records thread safe. A retained text snapshot can outlive a record according to `zircon_text`'s creator-thread retain/release contract.

Run standalone tests from this directory:

```sh
../../tools/zig build test
```

Tests use real temporary files for canonical/symlink deduplication, CRLF, atomic publication, permission preservation, disk conflict, actual permission failure, dirty-close decisions, identity reuse, sparse oversized-file refusal, lazy listings, and allocation-failure cleanup.
