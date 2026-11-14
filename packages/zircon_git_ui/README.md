# Zircon Git UI

Git presentation is separate from repository I/O, workspace persistence and the UI framework.

- `layout` builds file/hunk row maps for unified and split views. Expansion replaces only the selected file; new diff installations reuse unchanged file geometry. The renderer, scrolling, collapse, source hit testing and cursor navigation use those maps.
- `sources.ranges` turns hunks into source byte excerpts, merging overlapping context. `zircon_multibuffer` retains their source identities and revisions.
- `content.Content` renders the visible part of a comparison with a pinned file header and next-file push-off shared with Search. Host hooks supply file actions and live source canvases. The package does not import the application shell.
- `Editors` retains source editor selections and presentation. Text and undo remain owned by workspace documents.
- `review.Review` supplies an immutable text snapshot in unified, old-side or new-side display order. It reuses `zircon_editor.Editor` for selection, Unicode movement, word/line selection and copying. Its row map excludes file/hunk controls and split padding. Selection survives redraw and matching patch refreshes; history tabs retain their own review snapshots.

`zircon_git` performs Git I/O. `zircon_editor` handles source editing and protects optional excerpt edit scopes. `zircon_widgets` supplies shared colors and controls. The application connects jobs, source mutation events, saves, tabs and commands. Git source documents do not require source tabs. Live typing compares retained source/base text in a background job, independently of repository refresh. Wrapped source canvases shape the displayed excerpts rather than the complete source file.

Deleted, staged and historical text is selectable through the normal clipboard actions. A mutation touching immutable text is rejected before any source changes. Live mutations validate displayed bytes and source revisions, then use the shared multibuffer transaction owner for edits across files. Source documents keep their history; the review snapshot has no independent editing history. Both Git and Search use the same drag-autoscroll helper.

This does not provide a complete Zed display map. Projected UTF-16 coordinates, cross-source composition and large-project performance acceptance remain work. Git rows now share editor wrapping rules, with split padding, selection hit testing and context controls following the shaped row geometry. Each context arrow expands up to five lines at its own hunk boundary in the chosen direction, using captured comparison text without reading today's workspace for history. File/hunk headers and binary metadata are controls or informational rows outside the selectable code projection.

Run `./tools/zig build test-git_ui` from the repository root, or `../../tools/zig build test` here. The source study and current limits are in [the Git multibuffer implementation notes](../../docs/research/zed-git-multibuffer-2026-11-08.md).
