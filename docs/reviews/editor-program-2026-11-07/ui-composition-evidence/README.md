# Compact UI composition acceptance

Verified on macOS on 2026-11-07 with Zig 0.17.1. The change keeps eager frame-owned builders and introduces tuple child results, fallible modifiers/handlers, inline button metadata and callback-first payload inference.

| Command | Result | Evidence |
| --- | --- | --- |
| `./tools/zig build check --summary all` | 42/42 steps passed, including 112 framework checks, seven compile-fail contracts, compiled examples and documentation synchronization. Unchanged suites could be cached. | [Check log](check.log) |
| `./tools/zig build test-native-fresh --summary all` | 117/117 fresh native checks passed. | [Native log](native.log) |
| `./tools/zig build verify-recovery --summary all` | Five native crash/close/restart scenarios passed with the migrated application views. | [Recovery log](recovery.log) |
| `./tools/zig build test-build -Dtarget=x86_64-linux-gnu --summary all` | 14/14 compilation steps passed. This is portable compilation, not native Linux execution. | [Linux log](linux.log) |
| `python3 tools/migrate_ui_callbacks.py --from c4ce46e --check` | No old calls from that revision remain. | The fixed-revision tool and its CLI test enforce idempotence. |

The composition suite tests child order across tuples/arrays/slices, focus after reordering, inferred payload activation, child/handler failure before parenting, committed handler survival, owning sibling cleanup and allocation failure. A large heap-backed pointer-array test rejects duplicates without a large stack copy or recursive normalization.

Independent source review reproduced an intermediate stack overflow and array-normalization recursion, both fixed before acceptance. It also found lexical migration problems involving quoted text and comment newlines. Three tool tests cover these cases and repeat the CLI migration without changing non-code text.

The [before-fix compiler result](borrowed-error-before.log) shows that an entity read could return a pointer hidden inside an error-union field. [After the fix](borrowed-error-after.log), the expected ownership diagnostic closes that compile-fail contract. Entity results and callback payloads use the same recursive check, with separate fixtures for the two boundaries.

The [public guide](../../../zircon-ui-composition.md) and [design rationale](../../../design/ui-syntax.md) describe supported syntax and ownership limits. Native Linux/Windows, accessibility and the remaining editor features are still separate program work.
