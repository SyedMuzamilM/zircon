# Native scrolling measurements, November 11

This records synthetic scroll dispatch through the real Shell, layout, CoreText and Metal submission path. It does not measure physical trackpad delivery, GPU completion, display scanout, or performance against another editor.

The disposable fixture has 12,000 Zig lines, a local Git repository, and 1,000 separated search excerpts. Every twelfth line changes in the working tree. Each process warms startup and twelve scroll frames, then records 120 frames while scrolling down and back up. Every event must submit a frame; the maximum offset must exceed 1,000 pixels; document dirty state and fixture hashes must remain unchanged. No user preferences, remote services, or model calls participate.

Each case runs three times in separate processes. Cases rotate order by round. Compiler and test processes are stopped during recorded runs. The default fixture's wrap-enabled cases can fit most source lines; the separate long-line fixture repeats the sentence four times to exercise wrapped continuations. Global search retains its existing no-wrap behavior.

Reproduce with:

```sh
./tools/zig build build-bench-scroll -Doptimize=ReleaseFast
python3 tools/run_scroll_baseline.py --output /tmp/scroll-normal --runs 3
python3 tools/run_scroll_baseline.py --long-lines --output /tmp/scroll-wrapped --runs 3
```

`scroll_to_submit_ms` includes native presentation, including drawable acquisition. `dispatch_ms` is event dispatch alone. Optional `Window.profile_frames` counters split view construction, layout, scene preparation and native presentation. CPU preparation here means dispatch plus the first three phases; it omits uninstrumented App.step overhead and is not process CPU accounting. Timings near 8.3 ms in these runs mostly occur in presentation, so reductions in preparation do not imply equivalent reductions in frame submission time.

Raw JSON and executable hashes are retained for before/after runs. Environment `source_hashes` describe the workspace at collection time, not the source provenance of a previously built baseline executable. The baseline binary was preserved before the scroll optimizations; the driver hash identifies it. The workspace already contained uncommitted multibuffer and hover work. This is a bounded local comparison, not a release-wide latency guarantee.

The observed search bottleneck was repeated full excerpt traversal for both wheel handling and rendering. Git also repeated review geometry and gutter-width scans. Source excerpts now prepare syntax for their own visible runs; wrapped continuations share source preparation within a frame. Ordinary editor syntax-window behavior remains unchanged.

## Observed results

Values below are medians of per-process medians from `aggregates.json`.

| Timed work | Before, ms | After, ms |
| --- | ---: | ---: |
| Search wheel dispatch | 3.187 | 0.0046 |
| Search view construction | 6.389 | 0.078 |
| Search CPU preparation | 10.124 | 1.402 |
| Search input to submission | 10.391 | 8.330 |
| Git view construction | 0.500 | 0.331 |
| Normal editor input to submission | 8.362 | 8.411 |

Normal-editor submission did not improve reliably. The long-line before/after runs also overlap. Native presentation dominates many samples; unchanged frame totals do not negate reduced preparation, but they do limit the latency claim. Debug diagnostics are one run per case and are not a repeated before/after comparison.

The [interactive chart](overview.html) switches between CPU preparation and submission totals. `before`/`after` contain the main mixed-hunk fixture, `long-before`/`long-after` contain the long-line fixture, and `debug-current` contains the diagnostic Debug run.
