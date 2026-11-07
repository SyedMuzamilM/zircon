# Application recovery integration

The first slice of the [editor/platform program](../design/editor-platform-program.md) connects the existing recovery store to native startup, project windows, checkpoints, restore and close/discard policy. It preserves the original source files and disk fingerprints. Windows and Linux native execution are still open work.

## Design and ownership

Two independent design readers considered entity-owned jobs and a dedicated writer thread. Both used the session model, so this was independent reasoning without model diversity. The chosen design moves `Store` into one existing task and returns it through `Handoff`. Snapshots and captured metadata outlive the shell if the window disappears; the task queue joins the worker before creator-thread disposal. Recovery jobs are never canceled merely to supersede a checkpoint.

The application observes a small session fingerprint during its existing external drain. It compares document/content-state and disk identities, pane membership, selections, scroll and language metadata without copying text. A checkpoint captures retained snapshots only when due. The worker copies changed contents; unchanged content-state IDs reuse previously committed content references. Dirty checkpoints and clean-file reopen have different restore policies.

The framework adds `App.currentTime` and `Ui.requestFrameAfter`. Pending checkpoints schedule one committed frame deadline. The native event loop processes queued closes before sleeping, including requests made during task completion.

## Correctness review

Independent reviews found and prompted fixes for request-time window-discard validation, idle deferred close and recovery warnings erased by transient status. A targeted test then found that refusing a stale document close needed to schedule a new checkpoint after assigning a fresh persistent ID. A fresh review found that replacement stores must never resume another abandoned window and that close approval must be revalidated at the final close event. These boundaries now have dedicated application tests. The final focused source review returned VERIFIED, with runtime/platform limits stated separately.

The subprocess driver initially repeated a document-close operation after its target was gone. A later run exposed an acknowledgment observer that needed one queued wake while a task completed. Both corrections are in the verification tool. Before checkpoint startup, the driver relies on the actual native frame deadline in Vim Normal mode, without caret polling. Failed runs remain in the temporary evidence paths recorded in the [decision log](editor-platform-decisions.tsv).

## Verification

The integration suite adds fourteen application behaviors: exact dirty/untitled restoration and conflict preservation, exclusion before close, independent session locks, current-disk clean reopen, newer-edit refusal for window and document discard, failed-publication backup preservation with persistent warning, owner teardown during writing, bounded scheduling under sustained input, final-event revalidation for save and discard, preservation of another abandoned session, partial corrupt-record salvage and closing with recovery unavailable. The framework test checks deadline rollback and invalid delays against injected step time.

`./tools/zig build verify-recovery` runs three native SIGKILL/restart cases and two ordinary idle close/restart cases. It checks exact text, pane geometry, selections, focus, unchanged source hashes, conflicts after an external rewrite, document discard and whole-session discard. It is a correctness journey, not a performance benchmark or complete IME acceptance.

Final validation passed all 32 portable check steps, 91 application tests with four pre-existing skips, all 117 fresh native checks, and all five subprocess scenarios. [Preserved logs and results](../reviews/editor-program-2026-11-07/recovery-app-evidence/README.md) record the commands and caching limits.

Current limits are documented in the [editor guide](../editor-guide.md#recovery). Primary selections restore; full multicursor sets and undo history do not. Checkpoints use the existing bounded storage format and do not promise power-loss durability. Shared document-change delivery remains TEXT-07; the fingerprint observer avoids adding competing hooks to each edit origin while that contract is pending.
