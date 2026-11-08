# Zircon multibuffer

`zircon_multibuffer` is the source-backed projection used by editable Git, search, diagnostics and blame views. A `SourceId` is a workspace `DocumentId`. Sources retain immutable snapshots. Excerpts identify source ranges and receive stable excerpt identities. `setSources` installs multiple source snapshots and ordered excerpts atomically. The projection exposes concatenated bytes for the editor while `edit(ProjectedRange, replacement)` returns a source document ID, the source revision observed by the projection, and a source range.

Anchors store a source identity, byte offset and insertion bias. Apply a source `text.Change` to remap anchors and excerpt ranges before replacing the retained snapshot. A projected edit that crosses an excerpt or source boundary returns `CrossExcerptEdit`; callers must split or reject it before mutating a workspace document. A stale source revision returns `StaleSourceRevision`.

The core does not own workspace mutation or UI state. Callers group returned `SourceEdit` values into one workspace transaction policy and publish the resulting `DocumentChange` values. This keeps Git, search and diagnostics from editing unrelated files through a flattened row offset.

The implementation is intentionally smaller than Zed's full `multi_buffer`: diff transforms, language parse state, UTF-16 display points, virtualization and grouped undo integration remain follow-up layers. The source identity, excerpt mapping, anchor remapping and cross-boundary rejection are the first WORK-02 gate.
