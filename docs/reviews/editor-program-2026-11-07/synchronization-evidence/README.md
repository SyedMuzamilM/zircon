# Document-event and language-synchronization evidence

Verified 2026-11-07 with Zig 0.17.1 through `./tools/zig` on macOS/aarch64. Logs record fresh versus cached execution. Portable target builds establish compilation only.

| Command | Result |
| --- | --- |
| `./tools/zig build check --summary all` | 42/42 steps, 94 executed tests passed and four existing skips. Other suites reused earlier successful results. |
| `./tools/zig build test-native-fresh --summary all` | 12/12 steps, all 117 native checks executed and passed. |
| `./tools/zig build test-language-real --summary all` | 14/14 steps, all 118 checks executed and passed, including an installed clangd completion. |
| `./tools/zig build verify-recovery --summary all` | Five subprocess scenarios passed, including SIGKILL recovery. |
| `./tools/zig build test-build -Dtarget=x86_64-linux-gnu --summary all` | 14/14 portable compilation steps. |
| `./tools/zig build test-build -Dtarget=x86_64-windows-gnu --summary all` | 14/14 portable compilation steps. |

The 15 language fixture tests and rope-summary test executed successfully in the preceding full run, recorded in `review-fixes.log`. That run also caught a misspelled modifier in the new application test. The final full run passed after correcting it. No runtime change followed that final full check.

The read-only independent reviewer found invalid LSP ranges after standalone CR and incorrect Vim history origins. Both were corrected and tested against observable coordinates, subprocess-reconstructed server text and Shell events. The reviewer inherited the session model, so model diversity is reduced. No different-family judge is configured.

Verification reports correctness and exercised behavior. It makes no latency, memory-total, comparative Zed-performance or native Linux/Windows claim. Slow-server/coalescing acceptance, other document consumers, and the wider program remain open.
