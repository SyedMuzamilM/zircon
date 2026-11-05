# Native editor artifact baseline

Intended claim: record the ReleaseFast executable's on-disk size and the elapsed time/peak resident memory for five real file-open, render and PNG-export process runs per fixed input. This is a baseline, not a comparison with Zed, idle resident memory or interactive typing latency.

Use the installed Zig0.17.1 ReleaseFast artifact with `/usr/bin/time -l`. The executable's `--snapshot` path loads the actual document and lexical cache, creates a native AppKit/Metal window, prepares/presents the normal application frame, exports a PNG, reports the frame count and exits. Its internal timer includes initialization, source load, layout, glyph work, GPU snapshot and PNG encoding. External elapsed time also includes process startup/shutdown. Asynchronous project indexing starts normally and is canceled/joined at shutdown.

Inputs are deterministic generated UTF-8 Zig files. Alternate small and larger inputs for five runs each. Require exit0, `rendered_frames=1`, PNG signature/dimensions1240×820 and unchanged source hashes. Record every raw sample, machine load/core count, median and range. Report any failed sample instead of treating a fast rejection as successful work.

The run includes runtime Metal shader compilation, first-use system/font work and PNG encoding. It does not isolate their cost, and cache warmth varies across processes. No comparative performance conclusion or latency improvement is justified without profiling, live interaction workloads and equivalent Zed measurements. Source storage and viewport work have separate tests; those tests are not performance measurements.
