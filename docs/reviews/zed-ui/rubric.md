# Native editor UI review

Review the shipped Zed Preview 1.28.0 on this machine and Zircon at matching 1240 × 820 logical dimensions. The disposable EditorReview project contains the same Zig source and Git changes. Capture both One Dark and One Light. Zircon captures its actual native frame; its exported frames omit AppKit traffic lights, whose presence is checked separately in native tests. Zed window captures include native chrome and are normalized from the display's backing scale. This distinction must not be presented as a missing Zircon native window control.

Score each category from 0 to 2, with concrete evidence. Report all five subscores and their sum out of 10. Do not raise a score because a target was requested. Mark uninspected behavior as unverified. A screenshot does not prove keyboard behavior, Git semantics, responsiveness or accessibility.

1. Visual hierarchy and geometry: titlebar, tabs, breadcrumbs, tree, gutter, dividers and content density. Check clipping at narrow sizes.
2. Color and typography: selected text must be distinct from row focus, active/inactive text selection, light/dark surfaces, readable icons, measured text alignment.
3. Menus and controls: command palette, searchable font/theme pickers, popover anchors, dismissal, selected rows, keyboard hints and shared radii.
4. Editor interactions: ordinary/native text input, macOS deletion, continuous multiline selection, Vim modes and split focus. Use tests or observed actions for behavior.
5. Existing project workflows: Git stage/review/navigation, blame/hunks, search, Markdown and settings. Distinguish tested flows, inspected implementation and missing features.

This rates UI quality and the existing workflows above. Full Zed feature parity is a separate inventory, including terminal/debugger, arbitrary pane trees, LSP navigation/refactoring, collaboration and broader Vim support. A high score here cannot be reported as full feature parity. Missing or broken behavior within this rubric must reduce the relevant score.

Initial evidence is under `/tmp/zircon-ui-review/baseline`. The completed reference and candidate PNGs are retained in `docs/reviews/zed-ui/evidence/`, with exact hashes in `evidence/manifest.json`. Read `inspection.md` for capture methods, layout differences and tested scope. The baseline reviewer reports predate completion of the reference setup and must not be treated as final ratings.
