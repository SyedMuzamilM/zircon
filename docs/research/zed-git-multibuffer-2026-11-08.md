# Editable Git multibuffers

Zircon's Git tab now presents changed excerpts from live workspace documents, with source editing in unified and split comparisons. Repository I/O, visual controls, diff presentation and document editing have separate package owners.

## Upstream source inspected

Inspected Zed commit [`b5cd310b3b54dfc659fcc06453e6358843dfe216`](https://github.com/zed-industries/zed/tree/b5cd310b3b54dfc659fcc06453e6358843dfe216), dated November 7, 2026. A shallow source checkout was read locally. This work independently implements the architecture in Zig.

- [`git_ui/src/project_diff.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/project_diff.rs), especially `new_impl`, creates a HEAD-based `DiffBufferList` and a read/write `DiffMultibuffer`. The right editor is editable. The workspace item delegates save and editor actions to that view.
- [`git_ui/src/diff_multibuffer.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/diff_multibuffer.rs) owns a multibuffer and splittable editor, derives excerpts from changed source ranges, adds context and updates excerpts in path order. File/hunk controls act on the comparison while live text remains in source buffers.
- [`multi_buffer/src/multi_buffer.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/multi_buffer.rs), especially `edit_internal` and `convert_edits_to_buffer_edits`, maps display edits back to source buffers and maintains transaction history. Diff display transforms are separate from source text.
- [`zed/src/zed/app_menus.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/zed/src/zed/app_menus.rs) declares application menu groups backed by shared actions. This informed the File, Edit, Selection, View, Go, Terminal, Window and Help groups. Zircon also exposes a Git group.

## Package ownership

| Package | Responsibility |
| --- | --- |
| `zircon_ui` | Windowing, input, native menu creation, action delivery, layout and GPU rendering |
| `zircon_widgets` | Shared semantic colors, spacing, visual controls and popup framing |
| `zircon_git` | Repository queries/mutations, patch parsing, unsaved-buffer diff generation |
| `zircon_multibuffer` | Source snapshot identities, excerpt ranges, anchors and projected source mapping |
| `zircon_editor` | Source selections, text input, syntax, undo/redo, source canvases, excerpt edit limits |
| `zircon_git_ui` | Unified/split row projection, virtualized diff rendering, source excerpt construction, retained source-editor presentation |
| `apps/zircon` | Background jobs, workspace transactions, commands, tabs, save policy and Git actions |

## Behavior

Opening Uncommitted changes loads changed text files into workspace ownership, even if they have no visible source tab. Excerpts follow patch path order and retain only each hunk's source range and context. Unified and split layouts use the same row map for rendering, scrolling, file collapse, pointer targeting and hunk navigation.

Click a live context or added line to edit. Contiguous source rows render in one source canvas, including multiline selections. Pointer capture stays on the multibuffer container across redraws. Arrow navigation can move between displayed excerpts and files, skipping deleted rows and undisplayed source gaps. Shift-selection stays within its source excerpt. Removed rows, staged comparisons, commit history and the old side of split comparisons are read-only.

Typing updates the live source document. Unsaved bytes participate in diff refreshes without writing to disk. Source tabs observe the same document changes. Undo/redo uses that document's history. Save from the working comparison saves dirty documents included in the multibuffer. File staging continues to stage saved bytes, as its tooltip states. Saving and staging remain separate actions.

Application menus appear only in the platform menu bar. Their action catalogue uses the existing command dispatcher. Native menu targets resolve through the key window's responder chain. Clipboard actions go to the focused text input. The supplied cobalt Z image is embedded as RGBA for the runtime icon; packaging creates a matching ICNS and includes the original PNG.

## Limits

This does not establish full Zed parity. Cross-file selections and one undo transaction spanning several files are not implemented. Selection and mutations stay within one source excerpt. Hunk-level staging, conflict resolution, diff-aware find/replace and expansion of hidden context remain work. File staging, commit history, commits, branch/stash menus and network actions use the existing repository service. Images and binary changes retain textual Git metadata rather than editable excerpts.

## Verification

Behavioral package tests check excerpt/source mapping, hidden context, boundary rejection, split row targeting and collapsed geometry. Editor tests reject mutations outside the active excerpt and verify range remapping. App journeys edit live Git rows, select across redraws, undo/redo, save, switch split modes, protect historical rows and dispatch menu actions. Native journeys additionally inspect actual rendered geometry and invoke an AppKit menu item through the responder chain.

Build and verification results are recorded in [the delivery evidence](../reviews/git-multibuffer-2026-11-08/README.md).
