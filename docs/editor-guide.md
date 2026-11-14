# Using the editor

Build with `./tools/zig build`, then run `./zig-out/bin/zircon path/to/project` or pass a file. `./tools/zig build run` opens the current folder. Native execution requires macOS; portable tests also cross-compile for Linux.

Application menus appear in the native platform menu bar. File, Edit, Selection, View, Go, Git, Terminal, Window and Help dispatch the same commands as shortcuts and the palette. The titlebar shows the project and current branch. Click the project name to search recent projects or open another folder. Click the branch to switch or create a branch, or inspect stashes. The workspace menu opens files, extensions, settings, and commands. The bottom-left controls toggle project files, Git changes, and project search. The language-server control shows server state and diagnostics, with restart and stop actions. `Cmd+Shift+P` opens the palette, `Cmd+P` finds a file, `Cmd+F` finds in the current document, `Cmd+Option+F` opens replacement and `Cmd+S` saves. Closing a dirty tab/window asks whether to save or discard.

Drag a tab across its tab strip to reorder it. Drop a tab or project file near the left, right, top, or bottom editor edge to split in that direction. Each pane has its own tabs and active document. Git diffs, project search, and extensions open as tabs in the focused group. Open files and new documents appear in the focused pane. Use the split button to choose Split right, left, up or down, or use `Cmd+Option` with an arrow key. There are two editor panes; choosing a direction while split repositions the second pane. Close split merges the second pane's tabs into the first pane. Closing one view of a shared document keeps the other view and its unsaved text. `Cmd+Option+S` keeps the existing split toggle. Drag the dividers to resize panes or reduce the sidebar to 120 pixels. Project and Git sidebars keep separate widths during the session. Escape cancels a tab drag. The panes keep separate selections while sharing document bytes and history.

## Recovery

The native app checkpoints open documents under `~/Library/Application Support/Zircon/recovery`. Each project window owns a locked session. Opening the project after a crash restores available dirty and untitled text, pane membership, active panes, primary selections, scroll positions and language overrides. An explicit file argument still opens or selects that file after restoration. Clean saved files reopen their current disk contents.

Checkpoints wait for a 250 ms quiet interval, with a maximum scheduling delay of one second while typing continues. Slow writes, an existing writer or storage failure can delay successful protection beyond that interval. Work since the last successful checkpoint can be lost. A recovery checkpoint does not save the source file and does not clear its dirty flag. Restored dirty files retain their original disk baseline, so an intervening external write still causes a save conflict.

The recovery indicator in the status bar shows a persistent warning when a checkpoint fails. Hover it to inspect the failure and the age of the last successful checkpoint in this session. Click to request a checkpoint or retry a failed write. Storage initialization failures require resolving the error and restarting. Ordinary typing does not remove the recovery warning.

Discard closes only after the recovery exclusion commits. If the document changes while close is pending, the editor keeps the newer work. Closing one pane's view keeps a document that remains open in another pane. Clean window close checkpoints the final session; explicit window discard excludes that session from automatic restoration. Corrupt recovery records remain available for salvage while valid records restore. A corrupt index is reported and retained instead of overwritten.

Recovery currently preserves the primary selection in each view, rather than all multicursors or undo history. Session checkpoints are limited to 2,048 documents and 256 MiB total text, with a 64 MiB per-document limit. The storage contract covers process termination; it does not promise power-loss durability. `--snapshot` runs do not enable recovery.

Run `./tools/zig build verify-recovery` on macOS for the native kill/restart and idle-close checks. The command prints the directory containing its disposable projects and verification records.

## Terminal and language controls

Click the terminal icon at the bottom right to open or hide the terminal panel. The plus button creates another shell tab in the project directory. Click a terminal tab to switch sessions. Close a tab with its close button or `Cmd+W` while the terminal has focus. Hiding the panel keeps its sessions running.

Use the terminal toolbar's dock button, or the **Terminal: dock at bottom** and **Terminal: dock at right** commands, to change placement. Drag the divider to resize the panel. The `terminal_dock` preference persists as `"bottom"` or `"right"`. Each native session uses a macOS PTY with the user's login shell. Keyboard input, paste, Ctrl+C, ANSI colors, cursor movement, and bounded scrollback are supported. Full terminal-protocol compatibility has not been established.

The status bar shows Vim mode, cursor row and column, and the active document's language. Click the language to open a searchable language picker. The picker includes built-in lexical languages and installed extension languages. Selection changes highlighting and language-server resolution for that document without renaming its file. Use the language-server menu to install additional support.

Changing a document's language keeps unrelated language-server clients running. The rebound document gets a fresh session so late diagnostics from its old language cannot replace current results.

Hover a word in a language-server document to open symbol information after a short pause. The card shows the server's signature and Markdown documentation. `Option+Command+I` requests information at the current cursor. Editing, scrolling, moving away, or changing files dismisses stale information.

Hovering a symbol opens a compact language-server card sized to its rendered Markdown. Moving outside the symbol, card, or window dismisses it; editing, scrolling, and focus changes dismiss it too. Secondary-clicking a function opens the editor action menu and releases any source selection drag so menu clicks remain active.

The file-header options menu toggles soft wrap, inline Git blame, line numbers, indent guides, and Vim mode. The app always opens the editor layout, including when older settings select `"agentic"`.

## Git and search

`Cmd+F`, or the search icon to the right of the breadcrumbs, opens buffer search below the file header. The disclosure arrow toggles the replacement row. Match case, whole word and regular expression options control matching; the counter shows the current match and total. Enter and Shift+Enter navigate, as do the arrow buttons. `Cmd+G` and `Cmd+Shift+G` repeat the search even after closing the bar. Escape closes it and returns focus to the editor. Tab moves from the query to replacement; Shift+Tab returns.

Replacement supports `$1` and `${name}` captures in regex mode. Replace all is one undo operation. Matching runs in the worker after a 60 ms typing pause, rejects obsolete results, and supports Unicode. The current worker limits a buffer to 8 MiB and results to 20,000 matches; truncated searches disable Replace all. Invalid regexes appear in the bar. Project search below uses its separate search engine and does not gain these regex options.

Open the Git sidebar with the bottom-left Git icon. The Changes and History tabs share a wider sidebar with its own resize width. Changes groups conflicts, tracked files and untracked files into collapsible folder rows. The right-hand checkboxes stage or unstage individual saved files. The commit message field stays below the branch row, with the latest commit beneath it. Select a file for its worktree patch, switch to Staged to inspect the index, and use Stage/Unstage or their all-file variants. Enter a commit message before committing. Staging reads saved files on disk; it does not save an unsaved buffer. Git hooks/signing remain active. View diff opens the combined working patch, including untracked file contents. Diff rows use source numbers, the same editor font and source syntax as normal files, with restrained addition/deletion fills. Click an added or context line to edit its source, drag to select multiple lines, and use unified or split layout. Drag across added, context or deleted text and use Cmd+C or Edit > Copy. Copy includes the selected code without gutter markers or hunk headings. The old side, removed lines, staged comparisons and history stay selectable and read-only. Arrow navigation moves between displayed excerpts and files. Cmd+S saves dirty files included in the working comparison. Selection can span excerpts and files. Split selection stays on the side where the drag began. Replacing or cutting a selection that includes read-only text leaves all sources unchanged. Selections spanning live sources use one grouped undo transaction. Captured drags autoscroll beyond the page edge until release. Hunk staging remains work. Staging refreshes the visible comparison without replacing unchanged rows. The History tab opens actual commits and their numbered patches; the folder icon in the status bar returns to the project tree. Git status refreshes automatically. Use Refresh Git to reload branch and stash metadata.

Git additions use the same 6-pixel green gutter as the editor. Context expansion arrows replace raw patch headers. Each arrow reveals up to five captured lines at that boundary in its own direction; other hunks stay unchanged. Working-tree context remains editable; staged and historical context stays read-only. A faint active-line tint preserves the diff colors. Blue dots in file headers mark unsaved buffers. Cmd+S saves all retained Git buffers, including edited files whose last hunk disappeared, and clears their dirty dots after saving. Git comparisons follow the editor's word-wrap setting in unified and split views. Clicks and Up/Down follow wrapped continuations, including after resizing. Extension grammars run for all live files in an open Git comparison before you click a chunk.

The project sidebar checks for new, removed and renamed files once a second while preserving expanded folders. File names use green for added or untracked files, yellow for modifications and red for deletions in Git Changes.

Gutter markers compare current unsaved text with the index. New untracked and staged added files do not show line gutters or scrollbar change markers. Consecutive changed lines form one continuous strip. Click the strip to expand that hunk's removed lines in red and current lines in green. Modified words receive stronger highlights. Click again to collapse it. Expansion changes the display projection, not document bytes, dirty state or undo history. Line-number clicks retain normal cursor/selection behavior. The palette also provides next/previous change and expand/collapse changes at cursor commands.

Git strips are 6 pixels wide and touch the editor's left boundary. The wider gutter reserves separate space for line numbers and folding arrows. Hover the gutter to reveal arrows after the numbers; collapsed regions keep their arrow and an ellipsis visible. Click an arrow to fold or unfold. Folding preserves file bytes and works with wrapping and vertical navigation. Navigating to a hidden search match unfolds its enclosing blocks. Regions currently come from indentation, include matching closing-brace lines, and are cached by document revision. Syntax/LSP fold ranges and folding for files over 8 MiB are not implemented.

The current line shows its author and commit date after a short delay. Hover the author/time label to open commit details. The label is vertically centered within its source line; the floating card does not move source rows. The card remains open as the pointer moves into it, scrolls long messages, and offers Copy SHA. Click the label or use `Cmd+Option+B` to pin details. Escape, the close icon or clicking source dismisses the card. Uncommitted lines show an explicit working-tree state without a SHA. Blame uses unsaved text and rejects obsolete document revisions. Inline Git blame in settings controls automatic annotations; explicit blame remains available.

Git and global-search file headers stay pinned to the top of their content viewport until the next file pushes them away. Header buttons remain usable while pinned.

Git retains source documents without creating file tabs. Editing or expanding a Git excerpt leaves the tab list alone; Open File explicitly opens a source tab. Unsaved Git buffers remain owned by the workspace after leaving the Git view and participate in recovery and the window save prompt. Typing schedules a background buffer comparison using retained base text. Five-line expansion reads captured context and updates the selected file without a repository refresh.

Opening Changes shows all staged, unstaged and untracked changes in one scrollable HEAD-to-worktree comparison with file headers. Selecting a file reveals its loaded patch immediately without starting another Git job. Worktree/Staged commands still open individual comparisons. The combined view keeps staged changes visible until they are committed.

The branch button opens a searchable local/remote branch picker. Type a new name to create a branch; select a remote branch to track it. Arrow keys and Enter select entries, and lists scroll. The remote-action menu provides Fetch, Fetch from, Pull, Pull with rebase, Push, Push to, Publish branch, and Force push with lease. Pull uses fast-forward only unless rebase is explicitly chosen. Publish sets the upstream on the default remote, preferring origin. Missing remotes/upstreams and detached HEAD disable unavailable menu actions. Real Git errors remain visible in the panel.

Change actions offers Stage all, Unstage all, Stash all, Stash tracked, Pop stash and View stashes. Stash all includes untracked files; Stash tracked leaves them alone. Search the stash list, select a stash to inspect its actual patch, then Apply or Pop it. Apply retains the stash. Pop removes it only after applying successfully; conflicts keep it. Pull, branch changes and stash operations require saved file buffers. Clean open documents reload after worktree changes, while edits made during a background operation remain protected from replacement. These controls run ordinary Git commands in owned background jobs. This pass does not add hunk staging, destructive restore/discard menus, merge-conflict resolution or operation cancellation.


`Cmd+Shift+F` searches project files and open buffers. Unsaved text overrides disk; untitled documents participate. Results group context by source. Click a result to select the match in its original editable document. Change the query in the results toolbar and press Enter or Search to rerun it. Stale results report an error instead of using obsolete offsets. Result excerpts support source editing and selection across files. Project regex search and composition spanning multiple sources remain work.

## Extensions and language servers

Extensions opens the actual installed list. Install dev extension accepts a directory containing `extension.json`. Install Oxide installs the bundled example. Enable/Disable and Remove update effective contributions. Use theme/icon buttons to activate them; settings also lists enabled theme/icon choices.

The native app stores extensions under `~/Library/Application Support/Zircon/extensions` and preferences in the sibling `settings.json`. The [extension package guide](../packages/zircon_extensions/README.md) describes manifests, validation and atomic installation. The Extensions panel can search the full official Zed registry, install supported contributions, update packages and manage activation. It also offers common-language providers for languages Zed bundles in its core. Language-server adapters can install their servers in an extension working directory; some require Node.js/npm, Go or clangd. See [Zed compatibility and limits](zed-extensions.md).

`Ctrl+Space` requests completion. Click an item or press Enter to accept the first result; Escape dismisses it. Completion and additional edits form one undo operation. Responses must match server, URI, revision and request; changing the caret invalidates acceptance. Diagnostics below the editor navigate to their source. Disabling the providing extension stops its servers. Only versioned diagnostics are currently displayed.

## Previews and settings

Open an image path to view its decoded first frame through ImageIO. Its tab stays available while you inspect source files. Use the image toolbar to zoom out, zoom in, or return to 100%. Scroll to pan an image larger than its viewport. Close the image tab or press `Cmd+W` to return to source.

Open Markdown and choose Preview in its file heading, or Open Markdown preview in the palette. Editing source refreshes the adjacent preview. Click rendered text to reveal its source. Local links resolve relative to the Markdown file, and external HTTP/HTTPS/mail links use the OS opener. Local images use Zircon UI; remote images are not fetched. Scrolling and link hit testing reuse the prepared layout. Width, font generation, source revision and colors invalidate it. Offscreen primitives are skipped during painting, and source edits retain decoded images whose file identity and timestamps are unchanged. Source parsing and a newly invalidated layout still run synchronously; this is not full Markdown block virtualization.

`Cmd+,` or Settings in the workspace menu opens settings in a separate window above the workspace. Search filters individual setting rows across categories. Scroll the content to reach lower rows; theme, icon and font choices open searchable dropdowns. Option search is independent of settings search. Arrow keys select a choice, Enter commits it and Escape dismisses it without changing the setting. Edit in settings.json opens the persisted file in the workspace. Theme, icon theme, font size, tab width, line numbers, gutters and reduced motion affect shared editor state. The native app validates and writes preferences atomically before publishing them. Invalid files show an error and use in-memory defaults for that session. Closing settings leaves the workspace open. Changes made directly in JSON load on the next launch.

Appearance, Editor and Panels expand or collapse their nested navigation sections. Gutter and folding controls include indent guides, active-line highlighting and folding arrows. Project panel settings control file/folder icon visibility, default width and entry spacing. Search defaults and tooltip visibility/delay also have persisted controls. Keymap and Languages open the shortcut configuration and extension manager.

Installed file icon themes now apply through one resolver in the project tree, tabs, search results and Git file headers. Filename stems and suffix mappings both load their converted assets. Built-in controls still use `assets/icons`. Search fields have rounded theme-colored borders; icon buttons show delayed tooltips that stay inside the window and disappear when the pointer leaves.

Choose System in Color theme to follow macOS appearance changes in the editor, popups, settings, input fields and native window chrome. One Light, One Dark and installed themes keep their selected colors. `"theme": "zircon.system"` also selects System mode in settings.json.

The font pickers include the bundled faces and installed macOS font families. Search and use arrows/Enter to choose one. Editor and interface families are independent. The list creates rows only for visible choices. Family names persist in `font_family` and `ui_font_family`; bundled preset names such as `lilex` and `plex` remain valid. Core Text supplies its platform fallback if a configured family is unavailable.

## Editing and Vim

On macOS, `Cmd+Delete` deletes back to the logical line beginning. `Cmd+Fn+Delete` deletes to its end. At a line boundary these commands consume the adjacent newline, including CRLF. Option with backward/forward Delete deletes by word. `Cmd+Shift+K` deletes the current line. Ctrl+A/E, B/F and P/N move to the line boundaries, previous/next character and previous/next row; Ctrl+H/D, W, U and K delete backward/forward, backward by word, to the beginning and to the end. These editor commands keep document undo and split-view mapping. Search/settings text inputs support Command/Option deletion too.

Enable **Vim mode** in Settings > Editor, or set `"vim_mode": true` in settings.json and restart. Normal mode uses a steady block cursor. Insert mode retains the native caret, IME input and ordinary macOS editing keys. Escape, Ctrl+[ or Ctrl+C returns to Normal. The status bar names the active mode. Native text insertion is disabled in Normal and Visual modes; unsupported command text is consumed without changing the document. Search, command and settings fields retain ordinary typing.

| Task | Keys |
| --- | --- |
| Move | `h j k l`, arrows, `w b e`, `W B E`, `0 ^ $`, `gg G`, counts such as `12j` and `2d3w` |
| Other motions | `%` for matching brackets, `{ }` for paragraphs, `H M L` for visible rows, `+ -` for indented line starts |
| Scroll | Ctrl+U/D for half pages, Ctrl+B/F for pages, `zz zt zb` for cursor placement |
| Enter Insert | `i a I A`, `o O` with the current indentation |
| Select | `v` for inclusive character selection, `V` for whole lines, Ctrl+V for a rectangle; motions extend, Escape cancels |
| Operate | `d c y > <` followed by a motion; `dd cc yy >> <<` operate on lines; `iw` and `aw` select a word for an operator or in Visual mode |
| Edit | `x X s D C S`, `r` plus an ASCII replacement character, `J` to join |
| Find within a line | `f F t T` followed by an ASCII character |
| Search | `/ ?` open the find field; Enter searches and returns to the editor; `n N` repeat; `* #` search the current word literally |
| Register | `p P` paste the unnamed register, including linewise and rectangular contents; yanks/deletes also write the system clipboard |
| Block insertion | In Visual Block, `I A` insert before/after every selected row; `c` changes every selected range |
| History | `u`, Ctrl+R and `.` for undo, redo and repeat of the last supported edit |

Changes and the following Insert text share one undo group. Dot-repeat resolves the recorded command against the current cursor and applies its replacement as one document transaction. Visual changes and edits that leave the recorded insertion span are not dot-recorded. Vim state and registers belong to each pane. The two panes continue sharing document history.

This is the initial Vim command set, not full Vim compatibility. Macros, named registers, marks/jump lists, Ex commands, arbitrary text objects, Unicode arguments to find/replace commands and full grapheme-cluster motion remain work. `/` and `?` use the buffer find bar and its matching options. Motions currently step UTF-8 code points. Block selection uses shaped positions and expanded tabs; padding entirely new pasted rows uses source columns.

## Keyboard configuration

Add `key_bindings` to settings.json, then restart. Chords use `cmd`, `ctrl`, `alt` and `shift` followed by a key name. Actions use the command names from `apps/zircon/src/commands.zig`. A null value disables that chord, including its default action. Overrides apply to workspace commands, and menus display effective shortcuts. Ordinary text-field editing still uses the focused input's native editing keys.

```json
{
  "theme": "zircon.system",
  "git_inline_blame": true,
  "vim_mode": true,
  "vim_bindings": { "H": "0", "L": "$" },
  "key_bindings": {
    "cmd-ctrl-r": "split_down",
    "cmd-alt-down": null
  }
}
```

This adds a Split down shortcut and removes its default binding. `vim_bindings` independently remaps up to 64 single printable ASCII command characters in Normal and Visual modes. The example maps H/L to the line beginning/end. These mappings do not rewrite Insert text or focused input fields. Chords require Command or Control, accept at most 32 overrides, and reject unknown keys, internal-only actions and duplicate chords. This is a single-stroke workspace keymap. Context expressions, multi-stroke sequences and a graphical keymap editor remain future work.

## Package ownership

| Package/folder | Responsibility |
| --- | --- |
| `zircon_ui` | Entities, windows, layout, input, rendering, images, animations and task/inbox scheduling |
| `zircon_widgets` | Shared semantic colors, spacing and visual controls |
| `zircon_git_ui` | Git source excerpts, unified/split rendering and source-editor presentation |
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

## Word wrap

Option-Z or **Editor: toggle word wrap** switches between horizontal scrolling and viewport wrapping. The same choice is in Settings and persists as `"soft_wrap": "editor_width"` or `"none"`. Continuation rows repeat the source line's space/tab indentation, capped at half the available text width in narrow panes. This is a display offset; it adds no whitespace or line endings to your files. Carets, clicks and vertical navigation use the same indented geometry. Expanded inline Git change backgrounds cover both the gutter and source rows, including wrapped continuations.
