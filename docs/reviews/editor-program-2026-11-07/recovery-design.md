# Recovery design candidates

TEXT-05 is the next new feature slice after the immediate language-selection correction. This design is grounded in the current workspace persistence, Shell close paths, two-group panes and background task ownership. It is not an implementation or acceptance claim.

## Existing invariants

Runtime DocumentId includes workspace, slot and generation; persistent records need separate identities. Saved content state is a rope identity, not a revision. DiskStamp includes inode, size, modified time, permissions and SHA-256. Recovery must keep that original expected stamp. Loading today's disk and then overlaying backup bytes would silently adopt an external edit as the save baseline.

Snapshot read-only worker access is permitted while the UI retains it. Clone/deinit change UI-thread reference counts and must stay on that owner. Tasks join before creator-thread cleanup, which fits background checkpoint copying without borrowing mutable Shell state.

Closing only one pane's view does not discard the document. The explicit window-discard path currently closes without individually removing records; recovery exclusion must be committed before acknowledging that decision. Multiple windows can open the same root, so a project-path hash alone cannot identify the writer.

## Candidate A: immutable document checkpoints and atomic index

An independent design reader recommends one persistent window-session ID, persistent document IDs and a single session writer. Immutable versioned checkpoint files contain bounded header metadata and raw UTF-8 bytes with a length/hash. An atomic session index references exact checkpoint sequences and records ordered tabs/group membership, active views, focus, selections/scroll, split layout and language overrides.

Publish checkpoint files before the index, preserve the prior valid index/checkpoints, then collect unreachable records. Explicit discard needs durable exclusion/tombstones so an old worker cannot resurrect a discarded buffer even if the index is damaged. Serialize one current job and one latest pending capture per session; separate document jobs and delete jobs may otherwise publish out of order.

This limits rewrites to dirty documents and separates recovery storage from disk saves. It requires careful index/checkpoint/tombstone ordering and storage cleanup. Directory sync is required before promising power-loss durability; current save code's file sync alone does not establish it.

## Candidate B: append-only session journal

The parent considered a single checksummed, length-prefixed journal containing complete buffer checkpoints and metadata transactions, with explicit commit records and tombstones. Restore scans valid committed records and ignores a torn tail; compaction atomically replaces the journal. One writer and persistent session ID still apply.

A journal makes transaction order explicit and avoids an index pointing at missing document files. It adds a format parser, compaction protocol and potentially unbounded startup scanning. A malformed middle record complicates rescuing later documents; compaction can rewrite all retained buffers. These costs are not justified for the first recovery slice without measured sustained-edit workload pressure.

## Direction and acceptance

Prefer A, with bounded raw-text checkpoints and small metadata, subject to an implementation sketch and adversarial review of discard/save ordering. Restore creates new runtime IDs, leaves bytes dirty, never writes the original disk file and retains the checkpoint's original disk baseline. External changes/deletion keep recovered bytes but force conflict/Save As. Corrupt records are retained/quarantined and other documents continue restoring. Clamp restored positions to UTF-8 boundaries and reject nonfinite/unsupported layout values.

Checkpoint within a one-second maximum scheduling window with a short debounce, but report actual last successful checkpoint time: sustained typing, slow I/O or full disks can exceed that window. No previous successful backup is deleted when publication fails.

A real subprocess harness must edit saved and untitled buffers, use both panes, wait for a committed checkpoint marker, SIGKILL without destructors, restart and compare exact bytes/identities/dirty state/layout plus unchanged disk hashes. Add external rewrite between kill/restart, kill before checkpoint/index publication, explicit discard followed by kill, and one corrupt record among valid records. Graceful serialization alone does not pass TEXT-05.
