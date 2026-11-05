# Zircon search

Portable multi-buffer and project literal search. The package depends on `zircon_text`; it opens no window and never mutates documents or files.

```zig
var result = try search.search(allocator, io, .{
    .generation = generation,
    .query = .{ .text = "needle", .case_sensitive = true },
    .open_buffers = buffers,
    .files = paths,
}, cancellation);
defer result.deinit();
```

Each `Buffer` supplies `document_id`, optional path, title and an immutable retained `text.Snapshot`. The caller keeps snapshots, paths and query bytes alive until search returns. Workers only read the supplied roots; they must not clone or release UI-owned snapshots. A UI job releases those references after its worker has joined.

Open buffers are searched first. Their canonical paths suppress the disk version, even when unsaved text has no match. Untitled buffers are included. Repeated document IDs and canonical file aliases produce one source. Groups are sorted by path or untitled title. The package streams matching across rope leaves; it does not flatten open snapshots. Disk files are read under explicit limits and indexed in a temporary text document that is released between files.

`Results` owns one arena containing groups, match coordinates, merged context excerpts, source identities and errors. It can move, but must be deinitialized exactly once. Group/match/excerpt pointers expire with it. Match ranges and columns use UTF-8 bytes; lines are zero based. Excerpt `end_line` is exclusive, `source_range` identifies its exact source bytes, and `match_ranges` are relative to its copied `bytes`. Original CRLF bytes remain unchanged.

Activate a buffer result only if `group.isCurrentBuffer(document_id, current_snapshot)` succeeds. Disk activation can use `try group.isCurrentDisk(io)`, which compares identity, size, modification time and a streamed SHA-256 fingerprint. A false result requires refresh before using stored offsets. These checks do not lock another process out of a later file write. Results retain request generation; the host must also reject superseded request generations.

Case-insensitive search folds ASCII only. Whole-word mode treats ASCII letters, digits, `_`, and every non-ASCII code point as word characters. This is an explicit identifier-oriented policy, not Unicode word segmentation. Matching is literal and non-overlapping. Regex is not implemented and should not be advertised by callers.

Default limits are 8 MiB per source, 128 MiB of searched text, 10,000 matches, 20,000 examined input records, two context lines and a 64 KiB query. Override them through `Request.limits`. Reaching a limit sets `truncated`, meaning additional results may exist. Source errors include invalid UTF-8, NUL-containing disk files, oversized files, missing/changed files and I/O failures. Errors retain their source label and exact reason; valid groups remain available. Allocation failure or cancellation returns an error and discards the incomplete result rather than publishing partial state.

Cancellation is checked at source boundaries, during disk reads, every 4,096 matched/scanned bytes and while building excerpts. It cannot forcibly interrupt a blocked filesystem operation. The host runs search off its UI thread and maps its cancellation token through `Cancellation.context` and `is_canceled`.

Run with Zig 0.17.1:

```sh
./tools/zig build --build-file packages/zircon_search/build.zig check
./tools/zig build --build-file packages/zircon_search/build.zig test-build -Dtarget=aarch64-linux-gnu
```
