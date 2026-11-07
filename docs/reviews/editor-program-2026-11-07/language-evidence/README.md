# Language-selection lifecycle verification

The actual picker regression failed before the change: the unrelated client's identity changed from 4317031600 to 0. The three controlled-process journeys exercise shared clients, secondary-only synchronization, saved secondary state, repeated rebindings with bounded slot reuse, old unversioned diagnostics, A-to-B-to-A grammar output/failures, target completions, and retired resolver callbacks while an unrelated resolver completes.

The initial portable registration was missing from the native root. Shared `journeys.zig` now registers these scenarios for both portable and native application tests. The parent discovered that omission before accepting native coverage; the earlier native run is not offered as evidence that the new cases ran.

Disabling epoch guards triggered the intended grammar and resolver assertions. Later tests in that mutation run failed creating scratch directories with `NoSpaceLeft`; the mixed run is retained in `epoch-mutation.txt` and is not a clean two-failure result. Guards were restored. A subsequent exact-source portable run passed 66/70 with four native-only skips. A later shared-registry run has one additional test-discovery container, not another behavior test.

Independent review found an introduced Extensions status error: a retired scoped client overwrote a still-running shared client's label. The parent added a rendered-status assertion, watched it fail in `retired-status-before.txt`, then excluded retired sessions from that view.

Final native rendering chain: 95 passed, one explicit foreground-activation skip, 96 total. All 59 application checks, including the three lifecycle journeys, passed. Separate real-clangd chain: 93 passed, the same foreground-activation skip, 94 total. These chains repeat common tests; their totals must not be added as unique coverage. Foreground queue and full OS IME acceptance are not claimed from the skip.

The resolver work-directory regression failed when the helper opened the shared lock file without acquiring it. After acquiring the owned `File` lock, all five Rust worker tests passed in release mode, including every bundled grammar query. The lock test checks exclusion of a second writer, independence of another directory and availability after release. Configured built-in binary overrides return before acquiring an installation lock because they write no install cache.

The cache lock serializes writers to the same server work directory across resolver processes. It does not claim complete cancellation, safe arbitrary third-party extension side effects or protection against non-cooperating writers. Existing clients may still perform synchronous shutdown on the UI thread; general unversioned diagnostic freshness within one session remains LANG-08.

A stricter driver check now also requires the final Git gutter revision to match the current document and no pending Git refresh. The first compile incorrectly treated the scalar Git revision as optional; that compile failure is retained. A smoke accidentally launched with the preceding binary was rejected and moved to an owned temporary directory. Only a smoke built with the corrected check can establish this additional freshness condition.

The corrected current-Git smoke passed with 20 document revisions, 20 LSP changes,20 wrap builds and a final gutter revision equal to the document revision. Git commands coalesced to 48 in that single run. This is actual work/freshness validation, not a repeated latency sample or a claimed scheduling optimization. The complete matrix below uses this stronger check.

The complete repeated matrix with current Git readiness also passed 40/40. It is recorded under `../../../benchmarks/editor-2026-11-07-lifecycle-current-git/`; the invalid old-driver smoke contributes no result to that batch.
