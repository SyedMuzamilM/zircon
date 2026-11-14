# Git editing colors, local expansion and save indicators

Git source canvases now paint the normal active-line color at 16% opacity. The underlying addition tint remains visible, and the change gutter keeps its semantic color. Text selection continues to use the normal editor selection style.

Context expansion is stored per file and original base-hunk start. Clicking an up or down arrow adds five lines only on that side of the selected hunk, clipped at the file edge or neighboring excerpt. Separate arrows appear at the bottom and top of an omitted gap. The unchanged Zed expansion icons remain in use. Refreshing the diff reapplies expansion to matching base-hunk anchors.

Live working-tree file headers show a blue dot while their workspace document is dirty. Saving removes the dot once that buffer is clean. Cmd+S saves all retained Git source editors, rather than only the sources still represented by visible diff hunks. This fixes a lost-save case: editing a file back to HEAD can remove its last hunk while its on-disk contents still differ from the unsaved buffer. Normal workspace save/conflict checks remain in force.

The focused tests reproduce the previous opaque active-line fill, file-wide twenty-line expansion, and missed save after a hunk disappears. They now verify alpha-tinted active lines, independent five-line boundary controls, exact blue-dot geometry/color, multi-file save, dirty-marker clearing, and the disappearing-hunk case. The ordinary Git selection, context editing, word-wrap and native input journeys remain covered.

When expanded excerpts meet, hunk navigation falls back to the first code row instead of requiring an omitted-context header. A regression check reproduces the missing navigation target and verifies that navigation reaches the deletion row of the next change.

Verification on November 11:

- Focused Git application checks: 42 passed. Git UI package: 8 passed.
- Native Git canvas checks: 50 passed, 1 platform activation check skipped.
- Full fresh native suite: 179 passed, 2 platform activation checks skipped.
- Final optimized build: all 60 steps succeeded; 161 tests passed, 5 skipped. Rebuilt `zig-out/Zircon.app`.
- Native screenshots confirm the faint active-line tint, both blue file dots, and independent context arrows.
