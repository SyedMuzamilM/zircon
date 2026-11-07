# Native editing and update baseline

The intended claim is a repeatable baseline of the current editor's synthetic input-to-frame-submission cost and derived work on controlled local projects. This measures a release build of the real Shell, text model, native layout, CoreText and Metal path, with source verification. It is not a measurement of physical keyboard delivery, display scanout, general typing latency or performance against Zed.

Build the driver and its real grammar worker, then choose a new output directory:

```sh
./tools/zig build build-bench-editor extension-host -Doptimize=ReleaseFast
python3 tools/run_editor_baseline.py --output /tmp/zircon-editor-smoke --smoke
python3 tools/run_editor_baseline.py --output /tmp/zircon-editor-profile --profile
python3 tools/run_editor_baseline.py --output /tmp/zircon-editor-baseline --runs 5
```

The driver reads only generated fixtures and isolated settings/extensions. Each project lives in an owned temporary directory; disk bytes must remain unchanged. No remote/model request is sent and no user preferences are loaded. Results, diagnostics and source hashes survive fixture cleanup. Output directories must not already exist, so a rerun cannot silently replace earlier evidence.

## Workload

The repeated matrix has 32 KiB and 1 MiB UTF-8 Python sources, each with wrap off/on and core/services configurations. Every source has repeated indented long lines and Unicode comments. Services means a real local Git repository, the packaged built-in Python Tree-sitter worker and a deterministic stdio language-server fixture. Core disables those services to diagnose their contribution. It is a different feature configuration, not a competing editor or proof that services are unnecessary.

The driver warms the initial workspace/services, positions the caret at a middle source line, then alternates insertion of `x` and Backspace twenty times with a 50 ms idle gap between inputs. The gap is outside the timed region. CPU work adds to that interval, so this is not an exact 20 Hz arrival schedule. The initial generated text and final in-memory text must match, revision must increase twenty times, and every input must cause a frame submission. The final content is deliberately still dirty: insert/delete is editing, not undo to the saved content identity.

For every input the driver records:

- `dispatch_ms`, time in `App.dispatch`.
- `step_ms`, time in `App.step`, including UI-thread message installation, preparation/layout/paint and native submission.
- `input_to_submit_ms`, the combined interval. GPU completion and scanout are asynchronous and are not claimed.

After the burst, a separate settling interval waits for owned tasks, current diagnostics and syntax output. Git, LSP and parser work is counted over the burst and final settling. It is not all charged to the first visible edit. The `ready_ms` setup field begins after the expected-file verification read and `App.init`; it is not cold application startup time.

## Proof that the requested work occurred

Before timing, wrapped cases must have wrapping enabled in effective settings and more visual rows than logical lines. After timing they must have twenty wrap-cache rebuilds. This catches startup settings silently resetting wrapping.

Service cases must have a ready client, current document versions/diagnostics, current grammar spans, twenty queued LSP change messages, a Git status refresh and a syntax job. Failures, missing results, timeout and source mismatch make the runner fail; they are not discarded as fast samples. Git exit codes with valid alternate meanings, such as diff exit 1, are not classified as spawn/runtime errors.

The current driver also waits for the Git gutter revision to match the document
and for pending Git refreshes to finish. Older batches retain their own archived
driver and cannot retroactively claim this newer assertion. The
[current lifecycle matrix](editor-2026-11-07-lifecycle-current-git/README.md)
passes all forty attempts with that check enabled.

Cheap cumulative counters record Git command/status/history starts and process-run errors, LSP queued framed bytes/messages/changes, grammar jobs, wrap builds/shaped lines and fold-scanned bytes. Git counters are atomic; protocol stats use the transport mutex already protecting enqueue. These counters do not themselves prove precise wall-clock attribution or successful disk/network transfer. Protocol bytes mean queued frames, not wire traffic. The fixture's current diagnostics verify it processed current document text.

## Repetition, memory and profiling

Run each matrix entry in a fresh process five times, rotating case order by round. Keep all twenty samples per process. Report the median and range of per-process p95 values alongside the raw samples; twenty inputs make extreme tails coarse. Do not interpret a gap smaller than run variation as a reliable difference. No profiler or concurrent test/compiler load should run during the recorded batch.

The runner samples `ps` about every 100 ms and sums RSS for the driver and currently discovered descendants. Report it as sampled process-tree peak RSS. It can miss short-lived children/peaks and counts shared pages per process, so it is neither unique physical memory nor a true upper-bound peak. The sampler also has overhead, common to all configurations. The environment file records machine/OS/compiler, CPU/memory/load, dirty checkout status, source hashes and exact driver/worker hashes.

`--profile` runs one separate wrapped 1 MiB services workload. A readiness marker starts `/usr/bin/sample` around the edit burst. Its timings are excluded from the baseline. Sampling includes the deliberate idle gaps and background threads; inspect active main-thread stacks and actual work counts before naming a likely limiter. A one-second sample is evidence of observed work, not a universal performance attribution.

The baseline is valid only for these supported datasets/features. Large-file limits, real language-server analysis, filesystem latency, sustained unpaced input, remote Git, multi-hour sessions, GPU completion and foreground IME require further workloads under PERF-06 and TEXT-02. The current measurement is sufficient to record a pre-optimization local reference, not to claim those later gates passed.

A failed batch remains evidence of the failure, not a passing baseline. Report attempted and successful counts together, label successful-only latency summaries, and leave full feature acceptance open until a complete new batch passes. Never fill missing runs with selected successful retries.

On macOS, compile through `tools/zig` so the documented Darwin child-handle isolation applies. The runner records the wrapper, overlay helper and descriptor-regression hashes alongside the compiler and executable hashes. See the [complete post-fix baseline](editor-2026-11-07-isolated-spawn/README.md).
