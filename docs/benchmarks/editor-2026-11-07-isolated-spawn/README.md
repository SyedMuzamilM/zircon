# Editing baseline with isolated Darwin child spawning

All forty attempts passed, five fresh processes for each of eight configurations. All twenty service cases passed. No failed attempts were discarded or replaced. [Verification](verification.json) checks 800 total edits, exact final source restoration, unchanged disk files, real wrap work and current service results. The earlier [34/40 batch](../editor-2026-11-07/README.md) remains unchanged as failure evidence.

This is a passing controlled local reference after a process-isolation fix. It is not a speedup claim or comparison against Zed. Timing differences from the earlier batch include ordinary desktop load variation, and its failed service cases prevent a fair successful-only latency comparison.

## Root cause and fix

A captured grammar worker was blocked reading stdin while the Python language server retained both ends of that worker's input pipe. Its inherited writer prevented EOF. Zig 0.17.1's Darwin spawn path creates pipes then sets close-on-exec using a separate call, and did not request default close-on-exec at process spawn. The [private stdlib overlay](../../design/darwin-process-isolation.md) sets `POSIX_SPAWN_CLOEXEC_DEFAULT` while retaining explicit file actions. The deterministic regression fails with inherited handles 128/129 on the original compiler, passes with no unrelated inherited handles after the fix, and preserves an explicitly declared inherited handle.

[Live stacks and pipe endpoints](../../reviews/editor-program-2026-11-07/process-evidence/) preserve the cause. The unrelated work-validation failures from the first batch did not recur here; their exact failed counters remain unknown, so this report does not retroactively assign them a cause.

## Method and coverage

ReleaseFast, project-local Zig 0.17.1 with the Darwin spawn overlay, Mac15,12, eight logical CPUs, 16 GiB, macOS 27.0 build 26A428. See [environment.json](environment.json) for exact binaries, source hashes, load and dirty checkout. No profiler, compiler or native suite ran during the matrix. The user's existing desktop/editor processes remained running; this is not an idle dedicated benchmark host.

The [method](../editor-method.md) applies unchanged: 32 KiB and 1 MiB UTF-8 Python, wrap off/on, core/services, twenty alternating insert/backspace inputs per process, 50 ms untimed idle gaps, rotated configuration order. Services include real local Git, packaged Python grammar and deterministic LSP fixture. Core uses a different highlighting/service configuration, so it is not a feature-equivalent competitor.

Measured time is synthetic dispatch through native frame submission, excluding physical key delivery, GPU completion, scanout and background settling. RSS is sampled process-tree sum at roughly 100 ms, can miss peaks and counts shared pages per process. Each table value is a median and range of five per-process p95s, with only twenty inputs per process. All raw samples remain beside the summary.

| Source | Wrap | Configuration | Median p95 submission, ms | p95 range, ms | Median sampled tree peak, MiB |
| --- | --- | --- | --- | --- | --- |
| 32 KiB | Off | Core | 1.18 | 0.70–1.61 | 91.4 |
| 32 KiB | Off | Services | 1.21 | 1.20–1.25 | 113.7 |
| 32 KiB | On | Core | 1.80 | 1.51–2.55 | 92.7 |
| 32 KiB | On | Services | 1.29 | 1.28–1.30 | 114.6 |
| 1 MiB | Off | Core | 1.80 | 1.74–2.62 | 98.5 |
| 1 MiB | Off | Services | 2.95 | 2.87–2.99 | 216.0 |
| 1 MiB | On | Core | 12.97 | 11.84–16.66 | 99.2 |
| 1 MiB | On | Services | 10.95 | 10.80–11.04 | 305.1 |

## Remaining measured work

Successful services still queue twenty full-document LSP changes, about 0.67 MB for 32 KiB and 21.22 MB for 1 MiB. Git still starts 76–80 commands, including 19–20 status and history commands each. Wrapped cases rebuild their map twenty times while reshaping twenty edited lines. Folding still scans about twenty document sizes. These remain LANG-01/03, GIT-01 and PERF-01; fixing descriptor isolation does not optimize them.

The earlier separate sample profile remains evidence of observed wrap rebuilding and JSON serialization in that earlier binary. No new profiler-derived percentage or performance ranking is claimed here. BASE-03's controlled release-baseline gate passes; large-file/long-line policy, real language-server compute, cold startup, foreground IME, terminal process isolation and multi-hour reliability remain separate acceptance work.
