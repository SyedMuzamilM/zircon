# Zircon Git UI

Git presentation is separate from repository I/O, workspace persistence and the UI framework.

- `layout` builds immutable file/hunk row maps for unified and split views. The renderer, scrolling, collapse, source hit testing and cursor navigation use those maps.
- `sources.ranges` turns hunks into source byte excerpts, merging overlapping context. `zircon_multibuffer` retains their source identities and revisions.
- `content.Content` renders the visible part of a comparison. Host hooks supply file actions and live source canvases. The package does not import the application shell.
- `Editors` retains source editor selections and presentation. Text and undo remain owned by workspace documents.

`zircon_git` performs Git I/O. `zircon_editor` handles source editing and protects optional excerpt edit scopes. `zircon_widgets` supplies shared colors and controls. The application connects jobs, source mutation events, saves, tabs and commands.

Run `./tools/zig build test-git_ui` from the repository root, or `../../tools/zig build test` here. The source study and current limits are in [the Git multibuffer implementation notes](../../docs/research/zed-git-multibuffer-2026-11-08.md).
