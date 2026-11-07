# Wrapping, inline Git backgrounds and performance evidence

User-requested rendering fixes are complete. BASE-03 tooling and a 40-attempt release baseline are delivered, with full service acceptance still in verify status. Starting commit remains `cc199756e303012e4f6dcee0330568fd6d8b2831` plus the existing terminal/UI and documentation changes. No commits, pushes or changes to another thread's framework guides were made.

## Continuation indentation

Wrap rows now use the source line's leading space/tab width as a continuation indent. The display caps it at half of the available text width to leave room in narrow panes. Whitespace-only lines receive no extra hanging indent. Source bytes and line endings remain unchanged.

The row's existing source-to-visual translation includes this indent, so painting, hit testing, caret placement, selections, vertical navigation and blame label placement share one geometry. Indent guides remain anchored to the text gutter. Long words advance without creating a row containing only the leading indentation as a word-wrap boundary. Existing oversized-line limits remain.

Behavioral regressions cover spaces, tabs, mixed indentation, source preservation, row-width boundaries, clicks in continuation indentation, caret/up/down positions, deep indentation and unbroken Unicode progress. The requested case failed before the implementation and passes afterward.

## Gutter-spanning color

The canvas already painted full-width inline Git change bands, then erased their gutter portion with a later opaque gutter fill. Removing that redundant fill preserves the addition/deletion color across gutter and source. Intraline word-change highlights now stay clipped to their own wrapped segment and the text region. Existing full-width active-line coloring is retained across all continuation rows.

The composited-color regression compares gutter and source-edge pixels for removed and added rows with wrapping off/on. It failed before the fix. Native screenshots confirm continuous red/green bands and indented continuation text. Author/date blame labels and their floating detail card retain their existing geometry.

## BASE-03

Added a ReleaseFast native Shell driver, a deterministic Python fixture runner and cumulative counters for Git command starts/errors, LSP queued messages/bytes/changes, grammar starts, fold scan bytes and existing wrap work. Counters add observation; they do not change scheduling. They preserve the earlier transport shutdown fix and language-picker behavior in the shared dirty checkout.

The [method](../benchmarks/editor-method.md) explains the timed region, actual service coverage, correctness assertions and sampled process-tree memory. The [recorded batch](../benchmarks/editor-2026-11-07/README.md) preserves forty attempts, each configuration attempted five times. All twenty core cases passed; fourteen service cases passed. Four service cases timed out during grammar readiness, and two failed work validation. Every fixture file remained unchanged. Successful-only service timings are incomplete and cannot support a performance ranking.

A separate profile identifies wrap-cache rebuilding as the main observed active main-thread work in the 1 MiB wrapped workload. Successful service cases queue twenty full-document LSP changes and start 72–80 Git commands, including repeated status/history work. Folding scans approximately twenty document sizes during the burst. These provide concrete targets for GIT-01, LANG-01/02/03 and PERF-01 without claiming those tasks are complete.

Twelve subsequent diagnostic wrapped 1 MiB service runs passed. The failure is intermittent; those runs do not resolve it or replace failed baseline attempts. The current driver prints work counters and service state on validation failures to improve the next reproduction. Earlier development data with accidentally disabled wrapping was rejected; effective-mode, visual-row and actual wrap-build assertions now catch it.

## Verification and use

- `./tools/zig build check --summary all`: passed, 108 positive checks and four explicit skips in the executed check graph, including all 45 editor tests.
- `./tools/zig build test-editor-rendering-native --summary all`: 92/92 fresh native checks passed, including three rendering checks.
- `./tools/zig build test-language-real --summary all`: 90/90 passed in a separate invocation, including installed clangd. The shared native chain is repeated, not additional unique coverage.
- `./tools/zig build -Doptimize=ReleaseFast --summary all`: passed and installed the editor. Restart an existing Zircon process to load the new binary.
- `git diff --check`: passed.

[Logs, screenshots and final source/binary hashes](../research/evidence/wrapping-2026-11-07/README.md) preserve acceptance evidence. Measurement and native correctness runs were separate; native input checks ran sequentially. Other threads' existing terminal/UI/framework documentation changes remain in place.

## Next slice

BASE-03 remains unchecked. Diagnose intermittent grammar-host readiness timeouts and unknown work-counter failures, then run a complete new service baseline. LANG-02 retains the worker-lifecycle issue. TEXT-05 durable recovery is the next planned feature slice after the baseline gate. Performance scheduling, recovery, external watches and broader Unicode/IME acceptance remain open under their original checklist IDs.
