# Negotiated language synchronization

The client advertises UTF-16 and accepts UTF-16 or an omitted position encoding. Unsupported encodings fail initialization rather than silently sending wrong coordinates. Both integer and object `textDocumentSync` forms select None, Full or Incremental. The object form also controls open/close notifications.

Each tracked URI owns the last successfully enqueued immutable snapshot. Full servers receive full content. Incremental servers receive reverse-ordered ranges for disjoint insertions, deletions and replacements, with inserted bytes taken from the new snapshot. Ranges refer to the old snapshot, so applying a later range does not shift an earlier range. Queue failures preserve the retained version and snapshot for retry.

Missing events, undo, redo and ranges that split CRLF use a ranged whole-document replacement against the old snapshot. None synchronization emits no changes. UTF-16 coordinates recognize CR, LF and CRLF and keep Unicode separators as content. Normal LF/CRLF files use indexed rope lookup. A rope summary detects standalone CR without scanning normal files; standalone-CR coordinate conversion currently scans chunks and remains a performance follow-up.

The Shell uses exact mappings when one retained event connects the tracked version to the current version. Multiple intervening transactions currently use the replacement fallback. Output remains bounded by a 16 MiB queue. `Config.outgoing_limit_bytes` can lower that limit for pressure tests. This does not cap total process memory or implement a coalescing writer.

The subprocess fixture actually applies every received change and reports its reconstructed text in verification modes. Tests cover both capability forms, Unicode/multiline replacements, deletion, disjoint batches, undo, reopen, stale/invalid ranges, missing events, CRLF splits, standalone CR, Unicode separators, empty text, Full/None, and queue-pressure retry. Counters record serialized text bytes and enqueued changes; the insertion test checks one byte of change text, without claiming a latency improvement.

LANG-01 remains open for sustained slow-server/rapid-input behavior, application-level coalescing and broader integration evidence. Persistent parsing and navigation are separate work. See the [verification evidence](../reviews/editor-program-2026-11-07/synchronization-evidence/README.md).
