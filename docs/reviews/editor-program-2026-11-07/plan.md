# Editor parity program

The user authorized autonomous research, fixes, independent OpenCode/Antigravity reviews and local commits on November 7. No questions are required. Publishing, account changes and paid-provider configuration are outside the current implementation plan.

The installed reference is Zed Preview 1.28.0, build 20261104.153513, with exactly the binary hash recorded in the November 6 installed-app study. Existing screenshots remain historical; new captures must record their own timestamp and fixture. Do not copy personal preferences, credentials or user projects into review evidence.

## Acceptance

A review score is an opinion attached to a named commit, scope and actual evidence. Full parity requires the acceptance checks in `docs/editor-todo.md` to pass. Missing debugger, recovery, file watches, grapheme/IME/accessibility or language methods cannot become a 10 merely because a narrow UI review passed. Scores without runtime evidence must be marked unverified. No reviewer is asked to award a desired score.

Each implementation unit must have a reproduced behavior or explicit requirement, a small diff, appropriate behavioral verification, formatting/build checks, an independent review and a local commit. Public module/API documentation describes responsibilities, ownership, error behavior and non-obvious constraints. Avoid repetitive comments that restate function names.

## Workflow

- [x] Read pstack principles and runtime/model mapping; route the broad request with ask-matt.
- [x] Phase A: Frame. Capture the starting checkout and reference version; preserve prior work and existing evidence.
- [x] Phase B: Design the workflow. Keep the existing 88-task inventory as the dependency map; introduce no competing feature list.
- [ ] Phase C: Run the loop. Verify and commit one unit at a time. Baseline process isolation is fixed and a complete 40-case workload passes. Language-picker lifecycle is corrected; continue with recovery/document propagation and measured Git/LSP scheduling; keep settings/font/extension/Vim work tied to accepted journeys.
- [ ] Phase D: Keep the audit trail. Append decisions to decisions.tsv as evidence is produced.
- [ ] Phase E: Verify and hand back. Fresh native checks, repeatable performance work, independent review and honest remaining-gap inventory.

Initial review panel uses two different providers requested by the user: OpenCode GLM-5.3-Flash Free and Antigravity Gemini 3.8 Flash High. A fresh panel uses OpenCode Beam Free and Antigravity after the corrections. They inspect the actual dirty checkout, write separate reports only, and do not drive AppKit or run native tests concurrently. Findings need file/line evidence, a reproducible trigger, severity, proposed acceptance and explicit uncertainty. Parent performs its own review and owns integration.

## Review dimensions

UI/workflow fidelity; correctness and data safety; text/IME/Unicode; performance and memory; settings/fonts/themes; extensions/language services; Vim/keybindings; API/function design; formatting/documentation; verification/distribution. Each review records scope, score or unverified, blockers and evidence. External accounts/quota may block a reviewer; no substitute is silently presented as that reviewer.

## First concrete delivery

`bad2152` commits the already verified continuation indentation and gutter-color corrections with their behavioral regressions. The already delivered terminal/pane/UI work is preserved in `dc56004` after fresh verification. Framework documentation files owned by another thread are excluded from these commits.

BASE-03 passes after a complete new 40/40 batch with Darwin child isolation. The original 34/40 batch remains unchanged, including its four grammar timeouts and two unknown-counter failures. Live stacks and pipe endpoints explain the captured timeout; no cause is assigned retrospectively to unknown counters.
