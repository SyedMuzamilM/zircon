# Recovery storage unit

`./tools/zig build test-workspace --summary all` passes21/21 checks, including eight recovery-storage and restore tests. This unit is not connected to application startup or editing yet and does not close TEXT-05.

Storage uses one lock per persistent window session beneath a hash of the workspace root. Live sessions are isolated; a new window can claim an unlocked prior session. Text is raw immutable UTF-8 addressed by document ID and SHA-256. Atomic index publication follows content publication. Failed writes preserve the previous index, and cleanup runs only after a committed replacement. Corrupt text is retained under a preservation marker and other documents still restore. Corrupt index bytes are quarantined. Metadata-only publication reuses content references without rereading the full buffer. Document/session tombstones prevent stale publication from resurrecting explicitly discarded work. Persistent document IDs remain reserved even when their records were excluded or corrupt.

Workspace.restore creates a buffer directly from checkpoint bytes and the original DiskStamp, avoiding adoption of a newer disk baseline. A real external rewrite causes DiskConflict on save, preserving recovered content. Process-crash storage consistency is the scope; file sync does not prove power-loss directory durability.

Remaining acceptance includes UI-owned snapshot capture and cleanup, a single background writer, coalescing and errors, startup restore of both pane groups/selection/layout/language, discard hooks before acknowledgment, normal close/save policy and a real SIGKILL/restart journey. No crash recovery guarantee is exposed to users before these pass.
