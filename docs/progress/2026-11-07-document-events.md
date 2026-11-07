# Shared document events

The workspace defines `DocumentChange` with a `DocumentId`, typed origin, before/after revisions, resulting content-state identity and owned edit mappings. `Workspace.apply` transfers the transaction's existing mapping allocation into the event. There is no allocation after the text commits, so an allocation failure cannot commit text and then fail to return its event.

The Shell retains a UI-owned `ChangeLog` with at most 128 events and 1 MiB of mapping buffers. Publication transfers ownership and cannot fail. The log evicts old entries and discards oversized entries. Consumers must handle missing history by resynchronizing from retained snapshots. The limit covers mapping storage, not document history or process memory.

Direct editor input, completion, buffer search replacement and command edits publish through `applyOutcome`. Undo and redo publish reset events with empty mappings and their actual history action, including Vim commands. Publication and redraw notification survive a later view-update failure. The language service uses exact events when one retained event bridges its last enqueued revision to the current revision.

Remaining work includes other edit origins, event consumers for Git and recovery, and batching several retained transactions. Git still schedules repository refresh on edits. Recovery still fingerprints the session. These limitations keep TEXT-07 open.

Verification covers ordered identity/origin/revision delivery, command and Vim undo/redo, count and byte eviction, retained newest events, and allocation failure before transaction commit. See the [synchronization evidence](../reviews/editor-program-2026-11-07/synchronization-evidence/README.md).
