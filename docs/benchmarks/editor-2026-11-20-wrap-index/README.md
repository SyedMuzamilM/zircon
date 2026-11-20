# Wrapped typing baseline on macOS

All 40 attempts passed on a Mac15,12 with eight logical CPUs, 16 GiB RAM, macOS 27.0 (26A428) and Zig 0.17.1. The ReleaseFast build used Zircon `895e992` plus the benchmark and external-reload changes from this checkout. The [raw results](results.json) record the exact source and binary hashes, per-input samples, work counts and host load.

## 1 MiB results

Each row reports the median and range of five per-process p95s. Each process delivered 20 alternating inserts and Backspaces to the middle of an identical Python fixture with 50 ms untimed gaps. Git, Python Tree-sitter and deterministic stdio LSP were enabled in the services runs. The fixture answers automatic completion requests with an empty list. [Benchmark method](../editor-method.md)

| Configuration | Wrap | Median p95 submission | Range | Source lines reshaped per burst |
| --- | --- | ---: | ---: | ---: |
| Git, syntax and LSP | Off | 10.19 ms | 9.15–10.55 ms | 0 |
| Git, syntax and LSP | On | 9.42 ms | 8.91–9.82 ms | 20 |
| Core | Off | 6.79 ms | 6.19–7.38 ms | 0 |
| Core | On | 6.26 ms | 5.76–6.47 ms | 20 |

The wrap-on and wrap-off ranges overlap within each configuration. The run establishes a local baseline and confirms one reshaped line per edit in the wrapped workload. It measures synthetic dispatch through native frame submission. Physical keyboard delivery, GPU completion, scanout and final worker settling are outside that interval.

Every service run reached document revision 20 with current LSP diagnostics, syntax highlights and Git gutters. The driver required 20 queued LSP changes and waited for Git refreshes and owned jobs to finish. In the 1 MiB services cells, each burst queued about 20.2 MiB of LSP frames, and the syntax worker ran once during the burst and settling. Across all 40 runs, the final in-memory bytes and disk fixture matched the starting bytes, every input submitted a frame, and Git recorded zero process errors.

## Profile

The separate 1 MiB wrap-on services profile sampled the main thread 816 times. It caught 726 samples in the intentional sleeps and 75 in the timed step. View construction accounted for 53 step samples. The editor canvas accounted for most of those, including 40 samples in line-range lookup and two in fallback lexing. LSP synchronization accounted for 11 step samples, and the completion path triggered nine more during dispatch. Native submission accounted for two step samples. [Main-thread sample](profile-main-thread.txt)

Canvas preparation was the largest active stack in this sample. The workload also exposes repeated full-document LSP serialization. The profile counts sampled stacks and the November 7 baseline used a different completion fixture.

Two preliminary smoke runs failed when the older LSP fixture exited on the benchmark's completion position. The driver now checks for service errors between edits. A complete first matrix passed after the fixture repair. The reported matrix reran all 40 cases after adding the retry for a file modified during a reload read. The first matrix's summary is also in the raw results.
