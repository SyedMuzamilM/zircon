# Baseline verification evidence

These logs support the [November 7 progress record](../../../progress/2026-11-07-baseline.md). Starting commit `cc199756e303012e4f6dcee0330568fd6d8b2831` includes substantial uncommitted terminal/UI work. `source-manifest.tsv` hashes modified/untracked files outside this evidence directory at verification time. It identifies a working-tree snapshot, not an accepted commit or a clean checkout.

| File | Scope |
| --- | --- |
| `native-final.txt` | Final `./tools/zig build test-language-real --summary all`, all 90 native/real-server checks passed. Native execution steps are fresh; compiler cache hits are allowed. |
| `window-repeat.txt` | Five successive final `test-native-window` runs, all nine checks passed each time. |
| `window-input-mode.txt` | Window-bound input through the real first responder. |
| `queued-input-mode.txt` | Foreground queue check passed on this machine. This would record a skip if activation were unavailable. |
| `editor-fresh.txt` | Direct execution of the current editor suite, all 41 checks passed. |
| `portable-check.txt` | Final `check` result including formatting and compiler contracts. Unchanged portable execution results may be cached. |
| `dispatch-before-change.txt` | Ten initial focused runs with the original test arrangement passed. This was insufficient to establish a fix. |

The controlled two-window experiment and the stale settings-test failure are described in the progress record. The experiment deliberately asserted that an application-queued event stayed on its named window; AppKit delivered it to the current key window. The final tests assert the correct queued behavior and separately verify stable window-bound delivery.

These are local verification results. The new native CI job has not been run remotely in this batch. Logs are not measurements of editor performance or proof of complete foreground IME support.
