# Scrolling follow-up

The native scroll benchmark now exercises ordinary editor, Git and global search views with real Shell input, CoreText, layout and Metal submission. Three isolated release processes per case record 120 measured scrolls each, following twelve warmup frames. Source bytes and document state are checked after every run. Raw samples, executable hashes, the fixture runner and an interactive chart are in [the benchmark record](../benchmarks/scroll-2026-11-11/README.md).

The clearest bottleneck was global search. Both wheel handling and rendering repeatedly resolved every excerpt by scanning the entire projection and recalculating source line coordinates. With 1,000 excerpts, wheel dispatch took about 3.2 ms and view construction took about 6.4 ms. Search now retains mapped excerpt coordinates and aggregate row counts. Document changes update those coordinates along with the multibuffer ranges; source revision checks still reject stale data. Rendering skips groups outside the viewport and stops at its bottom. Measured wheel dispatch fell to about 0.005 ms and view construction to about 0.08 ms in this fixture.

Git now reflows the review geometry only when its layout changes. Maximum line-number/gutter metadata is computed when the projection is built, rather than scanning all file hunks for each visible row. Live selection painting inspects the selected row range and skips an empty selection. View construction fell from about 0.50 ms to 0.33 ms in the mixed-hunk fixture. Overall Git submission time remained near 8.3 ms.

Git and search source canvases prepare syntax metadata for their displayed runs instead of preparing up to 1,024 source rows per small excerpt. Ordinary editor syntax-window behavior is preserved. Wrapped continuations reuse the source text, expanded tabs and classified spans already prepared for their logical line within the current frame. These are bounded changes to preparation; the measurements do not establish a broad normal-editor latency improvement. A separate long-line workload showed normal-editor timing variation overlapping before and after.

Optional `Window.profile_frames` instrumentation reports view construction, layout, scene preparation and native presentation separately. It is disabled in ordinary application windows. Presentation includes drawable acquisition and Metal submission; these measurements cannot separate GPU completion or physical display latency. Normal-editor frame totals remained around 8.3–8.4 ms. Further work should profile queued native input and presentation under actual trackpad bursts, first-visit glyph work, large multi-file comparisons and long sessions.

A diagnostic run of the Debug build used more CPU for scene preparation than the release build. The delivered development bundle is therefore built with `ReleaseFast` after the Debug and native acceptance suites. This does not change the default build mode for contributors.

## Verification

The default build/check/install completed all 60 steps. The changed editor and Git UI suites passed, and the application suite passed 149 journeys with 5 platform skips in its focused run. The full fresh native suite passed all 177 checks, including source editing, wrapping, Git/search selection, menus, hover and settings. Benchmark source files remained unchanged.

The final `ReleaseFast` build/check/install passed all 60 steps with 467 passing tests and 5 platform skips. `zig-out/Zircon.app` is the optimized bundle. No commits were created, and earlier uncommitted work was preserved.
