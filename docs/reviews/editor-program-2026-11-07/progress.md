# Autonomous editor program progress

## Delivered

- `bad2152`: source-indented wrap continuations and continuous gutter/source Git backgrounds, with regressions.
- `0b73351`: private Darwin stdlib child-handle isolation, deterministic non-inheritance and explicit-inheritance regression, documented toolchain boundary.
- `dc56004`: preserved the already delivered terminal/workspace controls in a reproducible integration commit. Basic ANSI terminal and two pane groups remain the supported scope; broader EXT acceptance stays open.
- `33ee79c`: fresh native execution and input routing, measured editing/update counters, and verified release driver/runner. CI uses the process-isolated wrapper.

All 40 attempts in the new release baseline passed. The earlier 34/40 batch is retained unchanged. Live worker stacks and matching Python pipe handles establish the captured EOF failure. The exact failed counters in two old failures remain unknown. No latency improvement against the earlier batch or Zed is claimed.

Portable check, 92 fresh native checks, 90 checks including installed clangd, ReleaseFast install and 28 native UI capture scenarios passed after the runtime fix. The real-clangd suite repeats the shared native chain; these are not 182 unique native tests. Evidence is in `process-evidence/`, current UI captures in `current-ui/`, baseline data in `../../benchmarks/editor-2026-11-07-isolated-spawn/`. The latest post-lifecycle reference is `../../benchmarks/editor-2026-11-07-lifecycle-current-git/`, with current Git gutter results required.

## Independent review

OpenCode GLM-5.3-Flash Free and Antigravity Gemini 3.8 Flash High both returned ISSUES. Their original reports are retained. The parent checked the concrete findings in `triage.md`; some reported source claims and audit-trail claims were incorrect. Scores remain opinions of the scoped source reviews. Full-product 10/10 is not verified.

The parent's current verdict is NOT VERIFIED for full parity. Missing recovery/watchers, language navigation/refactoring, richer syntax classes, broader Vim commands/chords, arbitrary pane trees, full IME/grapheme/accessibility acceptance and long-session performance remain open checklist items. Font discovery, bundled fonts, searchable font selection and theme settings already exist; their current capture evidence does not establish every font's shaping behavior.

## Latest delivered units

`e08fdc5` fixes language-picker lifecycle without restarting unrelated servers. Document-scoped invalidation and fresh target-session identity reject old-language unversioned diagnostics; grammar/resolver epochs reject obsolete callbacks before they can alter pending state or publish errors. Live/saved secondary state and target completions are invalidated. Retired session slots are reused, and chrome, server popover and Extensions status exclude them.

`1f8f99e` protects shared resolver install directories with an owned file lock. Different server directories remain independent; configured built-in binary overrides skip cache locking when no installation is needed. Rust 1.89 is the declared minimum for the standard lock API.

A shared journey registry ensures the three lifecycle regressions execute in both native and portable suites. Final native rendering chain passed 95 checks with one foreground-activation skip; the real-clangd chain passed 93 with that skip. These repeat common tests. Five Rust worker release tests passed. ReleaseFast install passed all 42 build steps and 67 application checks with four explicit native-only skips. The release smoke validates actual wrap/LSP/parser/Git work; it is not a repeated timing comparison.

The initial epoch mutation caused both intended assertion failures, then later scratch-directory creations reported ENOSPC. That mixed run remains inconclusive as a full suite. Subsequent restored-source runs passed; only an owned superseded 228 MiB toolchain copy was removed, and no shared/global cache was deleted. See `language-evidence/` for the records.

Fresh cross-provider review remains the next acceptance step for these commits. Full parity remains unverified.

TEXT-05 durable recovery remains the next new feature after the cross-provider review. `recovery-design.md` compares immutable checkpoints with a journal and names forced-termination acceptance. Measured Git/LSP/folding/wrap scheduling work remains GIT-01, LANG-01/03 and PERF-01. No already tracked gap is dropped because this first unit passes.

## Current UI correction

`c23490e` delivers bounded grammar retries and error ownership. Six fixture journeys pass; the native chain passed102/102 at that revision. The current Git UI correction adds cursor feedback, joined action/menu controls, real per-file line-count badges, stable segmented branch/stash tabs and focused popover modules. Its current native chain passes105/105, and the ReleaseFast install passes42/42 steps with271 passes and four explicit native-only skips. These checks overlap previous chains.

The latest user screenshots refine the next editable-diff, header/toolbar, notification and syntax-performance work in `git-diff-next.md`. Recovery storage has a separate implementation under review; application integration and forced-termination acceptance remain open. Full-product10/10 remains unverified.
