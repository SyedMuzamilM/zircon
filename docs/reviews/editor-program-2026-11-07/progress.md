# Autonomous editor program progress

## Delivered

- `bad2152`: source-indented wrap continuations and continuous gutter/source Git backgrounds, with regressions.
- `0b73351`: private Darwin stdlib child-handle isolation, deterministic non-inheritance and explicit-inheritance regression, documented toolchain boundary.
- `dc56004`: preserved the already delivered terminal/workspace controls in a reproducible integration commit. Basic ANSI terminal and two pane groups remain the supported scope; broader EXT acceptance stays open.
- `33ee79c`: fresh native execution and input routing, measured editing/update counters, and verified release driver/runner. CI uses the process-isolated wrapper.

All40 attempts in the new release baseline passed. The earlier34/40 batch is retained unchanged. Live worker stacks and matching Python pipe handles establish the captured EOF failure. The exact failed counters in two old failures remain unknown. No latency improvement against the earlier batch or Zed is claimed.

Portable check,92 fresh native checks,90 checks including installed clangd, ReleaseFast install and28 native UI capture scenarios passed after the runtime fix. The real-clangd suite repeats the shared native chain; these are not182 unique native tests. Evidence is in `process-evidence/`, current UI captures in `current-ui/`, baseline data in `../../benchmarks/editor-2026-11-07-isolated-spawn/`.

## Independent review

OpenCode GLM-5.3-Flash Free and Antigravity Gemini3.8 Flash High both returned ISSUES. Their original reports are retained. The parent checked the concrete findings in `triage.md`; some reported source claims and audit-trail claims were incorrect. Scores remain opinions of the scoped source reviews. No product-wide10/10 is accepted.

The parent's current verdict is NOT VERIFIED for full parity. Missing recovery/watchers, language navigation/refactoring, richer syntax classes, broader Vim commands/chords, arbitrary pane trees, full IME/grapheme/accessibility acceptance and long-session performance remain open checklist items. Font discovery, bundled fonts, searchable font selection and theme settings already exist; their current capture evidence does not establish every font's shaping behavior.

## Active next unit

Fix the language-picker lifecycle without restarting unrelated servers. The chosen design uses document-scoped invalidation and new session identity for a rebound document, plus grammar configuration epochs. Previous-language unversioned diagnostics cannot be made fresh by merely attaching an internal revision. Design candidates and acceptance are in `language-lifecycle-design.md`.

TEXT-05 durable recovery remains the next new feature after this immediate correctness correction. Measured Git/LSP/folding/wrap scheduling work remains GIT-01, LANG-01/03 and PERF-01. No already tracked gap is dropped because this first unit passes.
