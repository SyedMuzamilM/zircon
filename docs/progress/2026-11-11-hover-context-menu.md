# Hover and editor context menu follow-up

Symbol hover cards now use compact Markdown metrics, fit their rendered content, and use the panel color and spacing expected for an editor popover. The card clears on pointer exit, source movement, edits, scrolling, focus loss, and outside clicks. The popup hit area accounts for whether it is placed above or below the symbol.

The editor action menu releases the source pointer capture as soon as it opens. This prevents a selection drag from consuming the menu click. The menu remains mounted through pointer release, movement and redraw, then activates Copy, Definition, Rename and related actions normally.

Portable tests cover hover dismissal and layout, menu redraw persistence and selection capture. Native tests cover AppKit right-click and menu action dispatch. Existing language-server and context-menu journeys continue to pass.

## Verification

- `./tools/zig build test-app -Dtest-filter='symbol hover'`: 7 tests passed.
- `./tools/zig build test-editor-native -Dnative-test-filter='context menu'`: 43 tests passed across the filtered native dependency graph.
- `./tools/zig build --summary all`: 60/60 steps succeeded, 149 tests passed and 5 skipped.
- Formatting, import ordering and `git diff --check` passed. The app bundle is `zig-out/Zircon.app`.
