# Zircon editor experience requirements

User-supplied requirements and screenshot references, received2026-11-05. They extend the original framework specification and independent Zig-framework/editor architecture. Screenshots depict Zed; retain them as product references, not claims about implemented Zircon behavior.

## Required behavior

1. Integrated native window chrome with macOS traffic lights, consistent dense tabs, project tree, breadcrumbs, status and command palette. Remove the separate default title strip. Preserve native dragging/resizing/fullscreen and keyboard operation.
2. Installable extensions for syntax/language definitions, themes, icon themes and language-server configuration. Enabling/disabling an extension changes editor behavior. The extension manager lists actual available/installed contributions and errors. Define the package format and loading policy explicitly.
3. Git line-change gutters, file/tab dragging and splitting, image viewing/loading and Markdown rendering. They use Zircon UI capabilities rather than an editor-specific native renderer.
4. Git changes and history sidebar, changed-file lists, working/staged diffs, staging/unstaging and commit UI. Clicking editor gutter/blame controls reveals real commit/author information inline. Repository operations use real Git results, retain data on failure, and update displayed state after changes.
5. Multi-buffer search groups actual matches by file and shows editable/openable context in the workspace, with navigation and match counts. Search current unsaved buffers as well as project files; stale results never overwrite newer revisions.
6. A separate settings window above the main editor, with integrated window chrome. Search/categories expose actual settings, apply changes to editor behavior, and persist them. Opening settings must preserve the workspace and focus return.

## References

- [Editor](editor-references/editor.png), [command palette](editor-references/command-palette.png), [extensions](editor-references/extensions.png).
- [Git changes](editor-references/git-changes.png), [Git history](editor-references/git-history.png).
- [Multi-buffer search](editor-references/multi-buffer-search.png), [settings window](editor-references/settings.png).

## Implementation rules

Use distinct packages for reusable Git/search/extension/language protocols. Keep native window/text/image adaptation inside Zircon UI. Keep editor document behavior outside native adapters. Use immutable snapshots and revision checks for asynchronous work. Menus/buttons must perform real labeled operations. Tests must exercise actual files, temporary Git repositories, extension manifests, language-server protocol messages, native window behavior and rendered artifacts as appropriate. A UI that only resembles these screenshots does not satisfy the feature requirements.
