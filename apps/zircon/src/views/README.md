# Finding and changing editor UI

Start with the feature that renders the control. Its module defines its input
text, creation options, layout and local handlers. `actions.zig` routes shared
editor commands; it does not create inputs or define their placeholders.

| Change | Module |
| --- | --- |
| Git commit placeholder, border, height, button or submission | `git/commit.zig` |
| Git sidebar sections, toolbar, branch row or latest commit | `git/sidebar.zig` |
| Changed file rows, staging controls and count badges | `git/files.zig` |
| Branch, stash or remote picker inputs and selections | `git/picker.zig` |
| Git command routing | `git/commands.zig` |
| Git network and change menus | `git/menus.zig` |
| Git comparison toolbar and hunk actions | `git/diff.zig`, `git/diff_controls.zig` |
| Commit detail header | `git/commit_details.zig` |
| Find and replace inputs and their layout | `buffer_find.zig` |
| Project-wide search input and results | `project_search.zig` |
| Extension search input and results | `extensions.zig` |
| Open project path and clone destination | `open_project.zig` |
| Command palette, quick open, path dialogs and dirty-close dialog | `overlays.zig` |
| Language picker or recent-project search input | `popovers/language_picker.zig`, `popovers/recent_projects.zig` |
| Project tree rows | `project.zig` |
| Tabs, breadcrumbs, titlebar and status bar | `chrome.zig` |
| Preferences controls | `../settings/view.zig` |
| Overall workspace/pane composition | `../view.zig` |

## Inputs

Each feature exposes a small `Fields` value containing its input entities and an
`init` function next to their configuration. `inputs.zig` assembles those values
once for the shell's entity lifetime and connects cross-feature observers. Access
is explicit, for example `fields.git_commit.message` or
`fields.project.destination`. Git pickers, project opening, path dialogs and
language pickers have separate entities, so opening one cannot reset another's
draft.

`input.zig` contains only input lifecycle operations: create, reset, read, watch
and apply appearance. It contains no feature text or layout. Theme updates use
the shared appearance, followed by feature-specific styling. The commit form
therefore stays borderless across theme changes.

Repository queries, subprocesses and document mutations remain in `services/`.
Reusable diff rendering remains in `packages/zircon_git_ui`; application-specific
buttons and callbacks remain here.

## Fluent composition

Use `const f = b.fluent()` and build the visual hierarchy with `column`, `row`,
`child` and `children`. Keep button labels and tooltip metadata in `button`
options; put sizing, styling, handlers and children in the fluent chain. A named
style preset such as `v.buttonStyle` is appropriate for shared visual defaults.
An optional `.on_click(null)` disables the button without a parallel layout.

Split a large screen into named sections that match what is visible. The Git
sidebar's `changesToolbar`, `changedFiles`, `branchRow` and commit form are examples.
Keep each chained operation readable on its own line when the layout is long.
Use trailing commas in child lists so `zig fmt` preserves their hierarchy.

`./tools/zig build check` checks compiler formatting, imports, eager-constructor
migration and fluent button layout. To migrate an older layout, run
`python3 tools/fluent_layout.py --expand <path>` and then `./tools/zig fmt <path>`.
