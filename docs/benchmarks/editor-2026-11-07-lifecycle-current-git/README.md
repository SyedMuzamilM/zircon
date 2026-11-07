# Current lifecycle baseline with Git freshness checks

All 40 attempts passed after the language-selection and resolver-lock changes. Every configuration completed five fresh processes. The driver now additionally waits for the current Git gutter revision and no pending refresh, as well as current grammar/LSP results. [Verification](verification.json), [summary](summary.json), exact [driver](driver.zig.txt), [runner](runner.py.txt) and all raw per-input samples are retained.

This supersedes the [preceding complete baseline](../editor-2026-11-07-isolated-spawn/README.md) as the current reference. The original [34/40 batch](../editor-2026-11-07/README.md) remains failure evidence. No timing improvement, ranking against Zed, physical key-to-display latency or universal budget is claimed.

## Method

ReleaseFast, Zig 0.17.1 through the private Darwin isolation wrapper, Mac15,12 with eight logical CPUs and 16 GiB RAM, macOS 27.0 build26A428. Exact source/binary hashes, checkout state and desktop load are in [environment.json](environment.json). This run used ordinary desktop load, not a dedicated idle host. No compiler, profiler or native test suite ran during the matrix.

The [method](../editor-method.md) applies:32 KiB/1 MiB Python UTF-8, wrap off/on, core/services,20 alternating insert/backspace events with 50 ms untimed idle gaps, rotated configuration order, exact final buffer/disk validation. Services use real local Git, the packaged Python grammar and deterministic stdio LSP fixture. Core disables those services and uses fallback highlighting; it is not a feature-equivalent competitor.

The timed interval ends at native frame submission. It excludes physical input, GPU completion, scanout and final background settling. Setup is warmed. Memory is a sampled process-tree RSS sum, approximately100 ms, which can miss peaks and count shared pages per process. Values below are medians/ranges of five per-process p95s, each based on only20 inputs. Separate dispatch/step samples are in the raw JSON.

| Source | Wrap | Configuration | Median p95 submission, ms | p95 range, ms | Median sampled tree peak, MiB |
| --- | --- | --- | --- | --- | --- |
| 32 KiB | Off | Core | 1.71 | 1.65–1.72 | 91.5 |
| 32 KiB | Off | Services | 1.22 | 1.20–1.23 | 113.9 |
| 32 KiB | On | Core | 2.53 | 2.48–2.70 | 92.6 |
| 32 KiB | On | Services | 1.28 | 1.26–1.41 | 114.4 |
| 1 MiB | Off | Core | 2.53 | 2.47–2.59 | 98.5 |
| 1 MiB | Off | Services | 2.88 | 2.85–2.90 | 308.2 |
| 1 MiB | On | Core | 13.20 | 12.96–13.31 | 99.2 |
| 1 MiB | On | Services | 10.82 | 10.76–10.95 | 313.3 |

## Coverage and limits

All 800 input revisions restored exact source bytes and left disk fixtures unchanged. Wrapped cases rebuilt the wrap map20 times. Service cases queued20 LSP changes, finished with current grammar/diagnostic versions, and could not declare readiness with an old Git gutter result or a pending refresh. Driver/worker hashes were unchanged through the batch.

Typing still causes document-wide folding scans and row-index work, repeated Git status/history commands, and full-document LSP serialization. Those performance gaps remain GIT-01, LANG-01/03 and PERF-01. Parser debounce coalesces this burst; it is not 20 incremental parses. The real-clangd correctness journey is separate from this fixture's performance data.

The earlier separate profile identified wrap rebuilding/serialization work in its own binary. This batch ran no profiler and makes no new percentage attribution. Large/long-line workloads, foreground IME, GPU scanout, cold startup, multi-hour memory/process reliability and external repository/file watching remain separate acceptance gates.
