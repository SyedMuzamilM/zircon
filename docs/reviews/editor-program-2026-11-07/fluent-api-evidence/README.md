# Fluent API verification

Verified on macOS/aarch64 with Zig 0.17.1 through `./tools/zig`. The source follows the existing const-render, frame ownership and typed callback contracts. The native counter, editor menu rows and project tree use the new chains.

| Command | Evidence |
| --- | --- |
| `./tools/zig build check --summary all` | `check.log`: 43/43 steps passed. 94 application checks executed with four existing skips; unaffected suites reused earlier results. Both embedded examples match compiled source. |
| Framework tests in the preceding check | `framework-and-recovery-finding.log`: all 122 framework checks passed, including nine fluent behaviors. That run failed a separate recovery timing assertion, corrected before the final full check. |
| `./tools/zig build test-native-fresh --summary all` | `native.log`: all 120 fresh native checks passed. |
| `./tools/zig build verify-recovery --summary all` | `recovery.log` and `recovery.json`: five real subprocess recovery scenarios passed. |
| Linux and Windows `test-build` | `linux.log` and `windows.log`: 14/14 portable compilation steps on each target. These are not native platform checks. |

The independent reviewer reproduced stale draft mutation after `Frame.discard`. Discard now leaves the frame retired until `reset` creates a new epoch. The new regression checks refusal after discard and confirms a stale chain cannot change a fresh node or poison its frame.

The recovery tests previously assumed a checkpoint remained busy after an app step. A sufficiently fast writer could complete and drain during that step. The revised conflict/discard and teardown tests queue the real checkpoint without draining completion, then exercise the intended lifecycle boundary. The continuous-edit test accepts a checkpoint that has already finished before the maximum-age observation. No recovery production behavior changed.

Two inherited-model design candidates supplied whole-element and pure-style alternatives. The chosen design uses eager element chains and the pure-style candidate's final-value validation and explicit unit policy. Model diversity is reduced; no different-family judge is configured. Independent implementation review found the discard bug and no other concrete parenting/callback/migration mismatch.

These results establish the implemented fluent subset. They make no comparative performance claim and do not establish native menus, new GPU backends, accessibility or complete editor parity.
