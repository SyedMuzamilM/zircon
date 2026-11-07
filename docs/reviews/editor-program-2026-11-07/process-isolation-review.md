# Process-isolation implementation review

An independent inherited-model source review inspected the wrapper, overlay helper, regression and Darwin spawn source. Its verdict was a qualified pass for default macOS wrapper builds: CLOEXEC_DEFAULT matches the existing explicit dup2/addinherit file actions, the lock/atomic publication is sound, and deterministic unrelated-handle and explicit-handle checks target the observed failure.

The reviewer flagged three limitations. The final implementation addresses the first two: cache identity and verification cover complete library contents, and conflicting `--zig-lib`/`--zig-lib-dir` overrides are rejected. Linux-hosted cross-compilation to macOS remains explicitly outside the accepted distribution route; ordinary macOS builds and macOS-to-Linux portable compilation use the correct target implementation. Direct `zig` bypass remains documented. The terminal raw fork/exec path is not covered by this stdlib correction.

The parent inspected the actual staged diff, reran the descriptor regression, checked both override refusal forms, then passed portable checks, 92 fresh native checks, 90 checks including real clangd, and a ReleaseFast install. The complete 40-case workload passed before the final cache/argument hardening; that hardening changes preparation/validation only, not the injected Darwin flag or editor runtime code. The two older unknown-counter failures did not recur; their causes remain unspecified.

Cross-provider re-review is still required before claiming broader process-lifecycle acceptance or a product-wide score. This review did not run native tests itself and does not claim every native process path is isolated.

The four cache-integrity tests now exercise unchanged source reuse, non-spawn source updates, cache corruption and unknown spawn implementations. `tools/zig` stops checking compiler flags at `--` so target-program arguments remain untouched. Both cache tests and an actual handle probe with a target `--zig-lib` argument passed.
