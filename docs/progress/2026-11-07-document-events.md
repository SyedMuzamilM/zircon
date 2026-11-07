# Shared document events

The workspace now defines `DocumentChange` with a `DocumentId`, origin, before/after revisions, resulting content-state identity and copied edit mappings. `Workspace.apply` creates an event from a transaction without exposing the mutable document record. The copied mappings make the event safe to retain after the original `text.Change` is released.

The application Shell owns an ordered queue of these values. Direct editor input, completion edits, buffer replacement and command edits publish typed origins through `applyOutcome`. The queue is UI-thread owned and has explicit disposal. This is the first consumer-facing seam for recovery, Git refresh, LSP synchronization, search and preview.

The current queue is an integration step, not the finished synchronization system. Language and Git still poll document revisions, recovery still fingerprints the session, and some agent/preview/project edit paths still need origin publication. The next slice should drain the queue into incremental LSP changes and Git buffer-diff scheduling, then remove duplicate whole-snapshot triggers where the new event is sufficient.

Verification includes a workspace transaction test for identity, origin, revision and stale rejection, plus an application journey that types text, observes one `.typing` event and clears the queue. `./tools/zig build test-app --summary all` passed 92 tests with four existing skips after this slice.
