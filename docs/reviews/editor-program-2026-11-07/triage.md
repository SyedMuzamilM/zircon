# Initial review triage

Antigravity's independent report is retained unchanged. Its scores describe a source-only opinion, not verified runtime acceptance. The parent checked the claims against the actual code and evidence.

## Accepted

- Choosing a language calls whole-model `language.deinit`, restarting unrelated clients. A fix must also reject previous-language grammar/diagnostic output at unchanged text revision.
- LSP changes serialize full text, folding scans the full buffer, and wrap updates rebuild document-wide row indices. Existing benchmark counters prove those workloads; optimization IDs remain open.
- Language navigation methods, richer syntax token classes and broader Vim registers/macros/chords remain genuine gaps, already tracked.

## Corrected or rejected

- Secondary-only source tabs remain in `tabs.items`. `panes.selectSecondary` flags an existing entry, and `closePrimaryTab` changes group flags. LSP polling visits that shared list; syntax polling explicitly includes the active secondary document. No omitted-pane defect is established.
- The decision log's rendering row cites `bad2152`, not `reference-inspection.md`. Its timestamp is after the commit and starting-state capture because the row records an already completed decision. That order is expected.
- The rendering suite and failed performance batch are distinct checks. The plan and baseline report explicitly preserve all six benchmark failures. A passing rendering row does not claim the performance gate passed.
- Pre-existing terminal/pane decisions belong to their original implementation and November 7 reconciliation, not retroactive entries attributed to this run. Their dirty source is captured by `starting-state.json`.
- Zircon's text storage is a persistent UTF-8 rope; this review does not establish a CRDT. Production IME duplication is not established by the earlier synthetic test routing failure.
- The terminal backend is Darwin-specific, behind the native application path. Linux native parity remains PLATFORM-02. A portable cross-build failure must be reproduced before claiming a new regression.
- Some task mappings in the review are wrong: LANG-04 covers definition/reference/symbol navigation; LANG-05 hover/signature/completion; LANG-06 workspace edits/rename/actions; LANG-07 formatting; LANG-08 diagnostics/lifecycle.

## New runtime evidence

A repeated native smoke reproduced grammar readiness timeout. A separate live sample caught the Rust grammar worker waiting in stdin read. The Python LSP process held both ends of that worker's stdin pipe, including its writer. That prevents EOF even after the parent closes its own writer. The installed Zig 0.17.1 Darwin spawn path creates pipes with pipe()/fcntl() and omits CLOEXEC_DEFAULT at spawn, leaving a concurrent inheritance window.

The deterministic `tools/verify_spawn_isolation.zig` probe inherited handles 128 and 129 before the fix. A private standard-library overlay adds Darwin CLOEXEC_DEFAULT while retaining explicit file actions. Its first probe inherited no unrelated handles. Further real-editor and declared-handle checks remain required; the timeout is not yet marked resolved.

Context7 documentation lookup returned an invalid-API-key error. Installed compiler sources and captured runtime evidence are the primary references for this issue. No account or key was changed.

## OpenCode follow-up

The OpenCode report correctly identifies failure-path grammar tracking and broad missing recovery/watch/navigation work. Its raw `zig version` saw the user's global 0.17.0. The repository wrapper and `.zigversion` use 0.17.1, matching the recorded benchmark; the global compiler was not changed. Its slow-Wasmtime hypothesis is superseded for the captured timeout by direct EOF/descriptor evidence. A 30-second read deadline can hide the inherited writer but cannot fix it. Remaining stdin-write/cancellation and retry policy are separate process-lifecycle work.

The full new matrix completed40/40 with the explicit-inheritance fix; six failures in the original batch remain historical evidence. The two original unknown-counter failures did not recur and are not retroactively attributed to a named counter. Cache identity now fingerprints all library contents; conflicting library overrides are rejected. Linux-hosted macOS cross-compilation is explicitly excluded from the accepted distribution path.

## Second cross-provider reviews

Both second reports are retained unchanged in `opencode-corrections.md` and `antigravity-corrections.md`. Antigravity accepts the correction scope based on source and retained evidence; its report did not execute checks. OpenCode returns ISSUES for a genuine grammar retry defect. The defect predates the lifecycle correction. Six new fixture journeys now cover bounded retries, malformed results, source freshness and error ownership; see `grammar-retry-evidence/`.

OpenCode's proposed diagnostic-loop change is rejected: breaking the matching-URI inner loop on a version mismatch discards that payload while the outer message loop continues. It does not stop draining other responses. Document-scoped sessions intentionally survive subsequent same-language edits to distinguish late unversioned diagnostics after a rebind. Slot reuse and unrelated client identity are tested. The requested review panel used distinct OpenCode Beam and Antigravity Gemini providers; a generic same-model warning does not describe that panel. The global compiler version differs from the repository wrapper intentionally.

Antigravity's recovery discard observation is accepted as an implementation requirement, not a current introduced defect: TEXT-05 is not yet installed. Synchronous language shutdown remains a genuine performance gap. Its benchmark build-failure claim does not match the retained runner: the runner explicitly requires a separately built artifact and records its hash; it does not compile a driver or ignore a build return code. The referenced failed manual build is preserved and followed by a successful explicit rebuild. Future runner integration may enforce build freshness directly, but the stated defect is not established.
