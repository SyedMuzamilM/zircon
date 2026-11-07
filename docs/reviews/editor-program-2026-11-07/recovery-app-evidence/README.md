# Application recovery acceptance

Verified on macOS on 2026-11-07 using the repository's Zig 0.17.1 wrapper. This is correctness evidence for TEXT-05, without a performance comparison, complete IME acceptance or native Windows/Linux claim.

| Command | Result | Record |
| --- | --- | --- |
| `./tools/zig build check --summary all` | All 32 steps passed. Some suites were cached; compiler contracts and formatting also passed. | [Portable checks](portable-checks.log) |
| `./tools/zig build test-app --summary all` | 91 passed, four pre-existing native-only skips, 95 total. | Application behaviors in `apps/zircon/tests/recovery_tests.zig` and existing suites. |
| `./tools/zig build test-native-fresh --summary all` | 117 passed. Compilation could be cached, but all native run steps executed. | [Fresh native checks](native-checks.log) |
| `./tools/zig build verify-recovery --summary all` | All five native subprocess scenarios passed. | [Verification results](verification.json) and per-scenario logs in this directory. |

The subprocess cases terminate a real native application with SIGKILL after an acknowledged checkpoint, then restart with the same recovery directory. They verify saved dirty and untitled text, layout, selections, active focus, unchanged original source hashes, external-write conflict protection and document exclusion. Two additional cases use ordinary idle Vim Normal window close, then verify saved session restoration and explicit whole-session discard.

The driver waits on the actual native checkpoint deadline before the writer starts. While a writer runs, it leaves one observer wake queued so its acknowledgment observer can see the result after the task completion drain. This observation policy does not supply the initial debounce wake. No source file is saved by the recovery driver.

The final focused independent source review accepted the store/snapshot ownership and close/fresh-session boundaries. The reviewers inherited the session model, so these checks had independent attempts without model diversity. Earlier rejected designs and failing harness runs remain described in the [progress note](../../../progress/2026-11-07-recovery-integration.md) and [decision log](../../../progress/editor-platform-decisions.tsv).
