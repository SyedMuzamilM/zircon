# Editing and update baseline, November 7

The core-only workloads completed five runs each. The service workloads are incomplete: 14 of 20 passed, four timed out waiting for grammar output, and two failed work-counter validation. All six failures remain in [summary.json](summary.json) and their named logs. The runner exited with status 1. Service performance comparisons are inconclusive; the timing table describes successful runs only and must not hide the failures.

BASE-03 now has a reproducible driver, raw input samples, work counts and failure evidence. Its full service-baseline acceptance remains open. This report claims no speedup, no ranking against Zed, and no general typing-latency budget.

## Environment and method

ReleaseFast, Zig 0.17.1, Mac15,12 with eight logical CPUs and 16 GiB memory, macOS 27.0 build 26A428. The checkout starts at `cc199756e303012e4f6dcee0330568fd6d8b2831` with the pre-existing terminal/UI changes and this batch. [Environment](environment.json) records source hashes, dirty paths, executable hashes and load. [Artifact verification](artifact-verification.json) confirms the driver and worker binaries did not change during the batch. Archived [driver](driver.zig.txt) and [runner](runner.py.txt) match this measurement; the current driver adds more failure diagnostics afterward.

The machine was in ordinary desktop use, including another interactive Zircon process and WindowServer activity. It was not an idle dedicated benchmark host. The matrix rotates order by round, but cannot remove desktop scheduling noise. Re-run on a controlled host before setting release budgets.

Each of eight configurations was attempted five times in a fresh hidden native process. Every successful run performed twenty alternating insert/backspace inputs with a 50 ms untimed idle gap. Source bytes, revisions, actual native submissions, effective wrapping, current language diagnostics and grammar revisions were checked. Services use real local Git, the packaged Python grammar worker and a deterministic stdio LSP fixture. Core disables those services and follows the fallback highlighting path; the two configurations are not feature-equivalent implementations.

The measured interval begins in synthetic `App.dispatch` and ends after `App.step` submits the native frame. It excludes physical keyboard delivery, GPU completion, scanout and the final background settling interval. Setup is warmed, not cold startup. See the [full method](../editor-method.md) for replication and limits.

## Successful-run measurements

The [core workload chart](overview.html) shows only configurations with five successful runs.

Values are medians and ranges of per-process p95 values. Each process contributes twenty raw inputs. A p95 from twenty samples is coarse. RSS is the sampled sum for the process tree, approximately every 100 ms; it can miss short-lived peaks and counts shared pages in each process.

| Source | Wrap | Configuration | Passed/attempted | Median p95 submission, ms | p95 range, ms | Median sampled tree peak, MiB |
| --- | --- | --- | --- | --- | --- | --- |
| 32 KiB | Off | Core | 5/5 | 1.66 | 1.32–1.73 | 91.5 |
| 32 KiB | Off | Services | 4/5 | 1.22 | 1.19–1.28 | 114.0 |
| 32 KiB | On | Core | 5/5 | 2.50 | 2.13–2.71 | 92.7 |
| 32 KiB | On | Services | 3/5 | 1.34 | 1.32–1.35 | 114.2 |
| 1 MiB | Off | Core | 5/5 | 2.37 | 1.78–2.69 | 98.3 |
| 1 MiB | Off | Services | 4/5 | 2.93 | 2.89–2.97 | 251.9 |
| 1 MiB | On | Core | 5/5 | 12.35 | 11.55–15.08 | 99.1 |
| 1 MiB | On | Services | 3/5 | 10.82 | 10.78–10.83 | 312.8 |

Dispatch and frame-step tails are also preserved in `summary.json`; the per-case files retain every individual sample. Separate percentile medians do not add up to the combined percentile. The core wrapped 1 MiB case has median dispatch p95 11.93 ms and step p95 0.54 ms, so most of its observed synchronous work occurs during dispatch. Successful services results have different highlighting behavior and fewer accepted runs. Do not read their smaller values as evidence that enabling services improves performance.

## Work that actually ran

| Counter over twenty inputs and final settling | Core | Successful services |
| --- | --- | --- |
| Git commands | 0 | 72–80 |
| Git status and history commands | 0 | 18–20 each |
| LSP changes | 0 | 20 |
| LSP queued framed bytes, 32 KiB | 0 | 668,501–668,521 |
| LSP queued framed bytes, 1 MiB | 0 | 21,216,901–21,216,921 |
| Grammar worker jobs | 0 | 1 |
| Wrap-cache rebuilds with wrapping on | 20 | 20 |
| Lines reshaped for those rebuilds | 20 | 20 |
| Folding scan bytes, 32 KiB | 655,370 | 655,370 |
| Folding scan bytes, 1 MiB | 20,971,530 | 20,971,530 |

Git status/history are still refreshed during ordinary typing. LANG-01 must replace unconditional full-document synchronization where the server supports incremental changes. The parser debounce coalesces this paced burst into one post-burst grammar job, so this is not twenty incremental parses. Full folding scans and row-index rebuilding still visit document-wide state, even though only the edited line is reshaped. Those costs belong to PERF-01 and LANG-03. All successful cases had zero process-run errors and restored exact in-memory text; all forty attempts preserved fixture files on disk.

## Separate profile

The [sampling profile](profile/profile.txt) is from a separate wrapped 1 MiB services run. Its latency values are excluded from the table. Most main-thread samples fall in the deliberate sleep gaps. Among active samples, 93 were in `wrap.Cache.ensure` under editor dispatch; 11 were in the language polling path, mostly JSON serialization/UTF-8 validation. Painting and Metal submission also appear. This points to wrap rebuilding as the main observed active UI-thread cost in this workload, not GPU scanout. A one-second sample cannot establish a universal percentage attribution.

A preceding [profile attempt](profile-timeout/summary.json) failed with `BackgroundTimeout`; its log is retained. It did not reach the profiling marker and contributes no timing result.

## Failures and remaining acceptance

- `32768-plain-services-1` and `32768-wrap-services-3` ended with `ServicesDidNotRun`. That driver version did not print the counter tuple on failure, so the exact failed counter is unknown. The current driver prints it and the service state. Do not assign these to a particular service without a reproduction.
- `1048576-plain-services-3`, `1048576-wrap-services-3`, `1048576-wrap-services-5` and `32768-wrap-services-5` logged `Extension host: Timeout`. Grammar work was no longer pending, grammar revision was absent, and LSP diagnostics were current at revision zero. These failed during initial readiness, before the input burst.
- Twelve subsequent diagnostic wrapped 1 MiB services runs all passed. They did not sample process-tree RSS and their timings are excluded. Their success shows intermittency, not resolution. [Diagnostic outcomes](diagnostic-outcomes.json) preserves their return codes and counters.

Investigate the worker pipe/lifecycle timeout under LANG-02 and unknown work-validation failures before accepting the full services baseline. Keep BASE-03 in verify status. Once fixed, rerun the entire matrix in a new directory and retain this failed batch as historical evidence. Do not fill missing samples with selected successful retries.

An earlier development batch was rejected because bootstrap settings disabled wrapping despite its requested case name. None of its values appears here. The current driver checks effective settings, increased visual-row count and twenty actual wrap rebuilds, which catch that mistake.
