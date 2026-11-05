# Zircon Text

UI-independent UTF-8 storage for the Zircon editor. This package imports only Zig's standard library. Documents use immutable AVL ropes with UTF-8 leaves of at most 4 KiB. Internal summaries index bytes, LF endings and UTF-16 units. Edits copy affected paths and boundary leaves; snapshots and history share untouched nodes.

```zig
const text = @import("zircon_text");
var document = try text.Document.init(allocator, "Hello 日本\n");
defer document.deinit();

var before = document.snapshot();
defer before.deinit();
var change = try document.apply(document.revision(), &.{
    .{ .range = .{ .start = 6, .end = 12 }, .text = "world" },
}, 0);
defer change.deinit();

const cursor = change.map(12, .after);
_ = cursor;
var current = document.snapshot();
defer current.deinit();
const line = try current.lineRange(0);
const bytes = try current.copy(allocator, line);
defer allocator.free(bytes);
```

## Ownership

`Document` owns its current root and history. Move owning values; a plain value copy does not acquire another reference. A successful `snapshot()` or `Snapshot.clone()` returns one owned reference; call `deinit()` exactly once. Snapshots may outlive their document. Strings passed to document construction or editing are borrowed only during the call and copied into immutable leaves when used. `Snapshot.copy` returns caller-owned bytes. `Snapshot.chunks` returns a borrowed streaming iterator; its snapshot must remain alive until iteration ends.

Reference counts, editing and history operations belong to the creator thread. Retain a snapshot before starting a worker. The worker may read immutable text, summaries, chunks and search results, while the UI keeps that retained snapshot alive. Join the worker before releasing its snapshot on the creator thread. Worker reads do not clone or release snapshots. Supply a suitable allocator for worker `copy` calls. Long search needles use `page_allocator` scratch; ordinary short searches use stack scratch. `debugValidate` is a creator-thread diagnostic.

## Edit and history contract

`apply(expected_revision, edits, group)` accepts sorted, nonoverlapping ranges in the old document. Endpoints must be UTF-8 code-point boundaries. Multiple edits with the same start are refused, including duplicate cursors; normalize selections before submitting them. Adjacent edits are allowed. All range and UTF-8 checks, history capacity and candidate-tree allocations finish before current content changes. An allocation or validation error preserves text, revision, state identity and undo/redo contents. Capacity reservations may remain available after a failed preparation.

`Change` owns offset-mapping metadata and records `before`, `after` and resulting content `state`. Release it with `deinit`. `map(offset, affinity)` maps an old valid document position through the batch. Positions inside replaced text map to the replacement's start or end. At an insertion, `.before` stays before inserted text and `.after` moves past it. Positions at the end of a nonempty replacement follow its replacement and are then mapped through any adjacent edit.

An edit, undo or redo increments the monotonic revision. Undo/redo restore a separate content-state identity, so a workspace can compare `stateId()` with its saved state. Replacements with identical bytes and empty batches make no new revision or history entry. A nonzero group coalesces consecutive edits with the same group into one undo step. Group zero creates a separate undo step. Undo, redo or `breakHistoryGroup()` ends coalescing. A new edit after undo discards the redo branch.

History retains at most 512 undo states by default. `setHistoryLimit` also trims retained redo states; zero disables new undo entries. The limit counts states, not bytes or whole-process memory. Large replaced regions can retain substantial memory while history or snapshots reference them. This is not a memory cap.

## Coordinates and search

All public `Range` and `Point.byte_column` values use UTF-8 bytes. `lineCount` includes the final empty line after a trailing LF. `lineRange` excludes LF and its preceding CR for display; `lineRangeIncludingEnding` preserves those exact bytes. A standalone trailing CR remains content. `pointAt` and `offsetAt` support raw byte columns up to a line's LF position, so existing CRLF byte boundaries round-trip. Display code should use the display range when clamping a visual caret.

`utf16Offset` and `byteOffsetFromUtf16` use indexed subtree summaries and refuse code-point or surrogate-pair interiors. `previousBoundary` and `nextBoundary` move one code point and treat CRLF as one line-ending step. They do not implement grapheme segmentation for combining marks, flags or emoji sequences.

`find(needle, from, direction, case_sensitive)` performs streaming KMP literal search, including matches crossing leaf boundaries. Forward matches start at or after `from`; backward matches end at or before `from`. Empty needles return no match. Insensitive matching folds ASCII only. Unicode normalization, full case folding and regular expressions are not implemented.

## Validation

From the repository root with Zig 0.17.1:

```sh
./tools/zig build --build-file packages/zircon_text/build.zig check
./tools/zig build --build-file packages/zircon_text/build.zig test-build -Dtarget=aarch64-linux-gnu
```

Tests compare deterministic Unicode edits with a flat reference, recompute AVL/summary invariants, exercise retained snapshots, group history and branching redo, map batch offsets, search across leaves, and inject failures throughout construction/edit/undo/redo allocation paths. Read-only worker access and teardown after document destruction are covered. No speed or memory comparison with Zed is established by these tests.
