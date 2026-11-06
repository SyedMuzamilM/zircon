# Using the editor

Build with `./tools/zig build`, then run `./zig-out/bin/zircon path/to/project` or pass a file. `./tools/zig build run` opens the current folder. Native execution requires macOS; portable tests also cross-compile for Linux.

The titlebar shows the project and current branch. Its trailing workspace menu opens files, extensions, settings and commands. The bottom-left controls switch between project files, Git changes, history and search; the bottom-right gear opens settings. `Cmd+Shift+P` opens the palette, `Cmd+P` finds a file, `Cmd+F` finds in the current document, `Cmd+Option+F` opens replacement and `Cmd+S` saves. Closing a dirty tab/window asks whether to save or discard.

Drag a tab across the tab strip to reorder it. Drag a tab or project file into the right part of the editor to open a second pane. Use the split button to choose Split right, left, up or down, or use `Cmd+Option` with an arrow key. There are two editor panes; choosing a direction while split repositions the second pane. Close split removes the second pane. `Cmd+Option+S` keeps the existing split toggle. Drag the dividers to resize panes or reduce the sidebar to 120 pixels. Project and Git sidebars keep separate widths during the session. Escape cancels a tab drag. The panes keep separate selections while sharing document bytes and history.

## Git and search

Open Git with the branch control or bottom-left Git icon. The Changes and History tabs share a wider sidebar with its own resize width. Changes groups conflicts, tracked files and untracked files into collapsible folder rows. The right-hand checkboxes stage or unstage individual saved files. The commit message field stays below the branch row, with the latest commit beneath it. Select a file for its worktree patch, switch to Staged to inspect the index, and use Stage/Unstage or their all-file variants. Enter a commit message before committing. Staging reads saved files on disk; it does not save an unsaved buffer. Git hooks/signing remain active. View diff opens the combined working patch, including untracked file contents. Diff rows use source numbers, syntax colors and restrained addition/deletion fills. Staging refreshes the visible comparison. The History tab opens actual commits and their numbered patches; the folder icon in the status bar returns to the project tree. Refresh Git after external repository changes.

Gutter markers compare current unsaved text with the index. The current line shows its author and commit date after a short delay. Click that annotation or the left gutter to open a detail card, or use `Cmd+Option+B` and the palette's Git: toggle line blame action. The card shows author/email, a wrapped commit-message preview, UTC date, short SHA and Copy SHA. Escape, the close control or clicking the same gutter line closes it. Uncommitted lines show an explicit working-tree state without a commit SHA. Blame uses unsaved text and refuses results from obsolete document revisions. Turn off automatic annotations with Inline Git blame in settings; explicit blame remains available.

`Cmd+Shift+F` searches project files and open buffers. Unsaved text overrides disk; untitled documents participate. Results group context by source. Click a result to select the match in its original editable document. Change the query in the results toolbar and press Enter or Search to rerun it. Stale results report an error instead of using obsolete offsets. Regex and direct editing in a combined search buffer remain work.

## Extensions and language servers

Extensions opens the actual installed list. Install dev extension accepts a directory containing `extension.json`. Install Oxide installs the bundled example. Enable/Disable and Remove update effective contributions. Use theme/icon buttons to activate them; settings also lists enabled theme/icon choices.

The native app stores extensions under `~/Library/Application Support/Zircon/extensions` and preferences in the sibling `settings.json`. The [extension package guide](../packages/zircon_extensions/README.md) describes manifests, validation and atomic installation. Contributions include colors, symbol/PNG icon mappings, language associations/lexical rules and executable/argv server configurations. Server executables must already be installed; configuration does not download a server.

`Ctrl+Space` requests completion. Click an item or press Enter to accept the first result; Escape dismisses it. Completion and additional edits form one undo operation. Responses must match server, URI, revision and request; changing the caret invalidates acceptance. Diagnostics below the editor navigate to their source. Disabling the providing extension stops its servers. Only versioned diagnostics are currently displayed.

## Previews and settings

Open an image path to view its decoded first frame through ImageIO. It remains separate from text documents. Editor returns to the previous text, and `Cmd+W` closes image viewing.

Open Markdown and choose Preview in its file heading, or Open Markdown preview in the palette. Editing source refreshes the adjacent preview. Click rendered text to reveal its source. Local links resolve relative to the Markdown file, and external HTTP/HTTPS/mail links use the OS opener. Local images use Zircon UI; remote images are not fetched.

`Cmd+,`, the status-bar gear, or Settings in the workspace menu opens settings in a separate window above the workspace. Search filters individual setting rows across categories. Scroll the content to reach lower rows; theme and icon choices open dropdowns. Edit in settings.json opens the persisted file in the workspace. Theme, icon theme, font size, tab width, line numbers, gutters and reduced motion affect shared editor state. The native app validates and writes preferences atomically before publishing them. Invalid files show an error and use in-memory defaults for that session. Closing settings leaves the workspace open. Changes made directly in JSON load on the next launch.

Choose System in Color theme to follow macOS appearance changes in the editor, popups, settings, input fields and native window chrome. One Light, One Dark and installed themes keep their selected colors. `"theme": "zircon.system"` also selects System mode in settings.json.

## Keyboard configuration

Add `key_bindings` to settings.json, then restart. Chords use `cmd`, `ctrl`, `alt` and `shift` followed by a key name. Actions use the command names from `apps/zircon/src/commands.zig`. A null value disables that chord, including its default action. Overrides apply to workspace commands, and menus display effective shortcuts. Ordinary text-field editing still uses the focused input's native editing keys.

```json
{
  "theme": "zircon.system",
  "git_inline_blame": true,
  "key_bindings": {
    "cmd-ctrl-r": "split_down",
    "cmd-alt-down": null
  }
}
```

This adds a Split down shortcut and removes its default binding. Chords require Command or Control, accept at most 32 overrides, and reject unknown keys, internal-only actions and duplicate chords. This is a single-stroke workspace keymap. Context expressions, multi-stroke sequences and a graphical keymap editor remain future work.

## Package ownership

| Package/folder | Responsibility |
| --- | --- |
| `zircon_ui` | Entities, windows, layout, input, rendering, images, animations and task/inbox scheduling |
| `zircon_text` | Persistent bytes, snapshots, coordinate indexing and history |
| `zircon_workspace` | File identities, safe saves, dirty state and project navigation |
| `zircon_editor` | Selections, commands, lexical profiles, decorations and text canvas |
| `zircon_git` | Git commands, records, patches, history, blame and line comparisons |
| `zircon_extensions` | Validated local manifests, activation and immutable generations |
| `zircon_search` | Snapshot/disk matching, source stamps and grouped excerpts |
| `zircon_language` | Stdio JSON-RPC, processes, diagnostics/completion and UTF-16 coordinates |
| `zircon_markdown` | Owned source-ranged Markdown parsing |
| `apps/zircon/src/services` | UI-owned transports, immutable jobs/results and effective contributions |
| `apps/zircon/src/views`, `settings`, `panes.zig` | Product screens, shared settings and captured pane interactions |

[Implementation status](status.md) records current limits and verification evidence.
