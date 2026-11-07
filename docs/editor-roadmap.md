# Editor delivery roadmap

Updated 2026-11-07. This roadmap turns the [Zed comparison audit](research/zircon-vs-zed-audit-2026-11-06.md) into scheduled work. The [editor checklist](editor-todo.md) is the source of truth for task status, ownership and acceptance. The original [framework plan](implementation-plan.md) remains the framework reference.

BASE-01, BASE-02 and the native-test routing correction in TEXT-01 are complete. See the [November 7 progress record](progress/2026-11-07-baseline.md) for current evidence and remaining EXT acceptance. BASE-03 now has a [complete40-case release baseline](benchmarks/editor-2026-11-07-isolated-spawn/README.md). The captured grammar timeout was caused by inherited pipe handles and fixed by Darwin child isolation; the earlier failed batch remains evidence. TEXT-05 recovery remains the next feature slice, with the newly verified language-picker session-lifecycle defect handled as an immediate correctness correction.

## Target

First deliver a dependable macOS coding editor: recover work, notice external changes, edit Unicode correctly, navigate language information, search and replace across a project, build/test in a terminal and review/commit changes. Then expand toward the remaining Zed capabilities.

The later phases keep every audited gap visible without making collaboration, remote development or another desktop platform a dependency of a useful local editor. A task is complete when its user-visible acceptance condition is demonstrated, not when a button or protocol method has been added.

## Existing work and ownership

The terminal/UI implementation is <t3-thread://v2/b79b85d5-1375-4bbb-b783-8d130943f509/7afede22-0b3c-411f-8a04-0d7929d6e6cd>. Its runs completed on November 6 and were reconciled on November 7. Changes remain uncommitted in the same checkout and branch; preserve them when claiming subsequent work. Read the progress record and actual checklist status before editing overlapping files.

That delivered scope and its remaining acceptance are tracked as EXT-01 through EXT-08 in the checklist:

| Reserved scope | Boundary for subsequent work |
| --- | --- |
| Wrapped-line active background | Reserve canvas/rendering bug fixes until the current result is verified. |
| Compact status bar, panel toggles and language-server information | Language-service internals can be planned independently; coordinate their UI integration with this implementation. |
| Language picker and mode/caret/language status | Preserve its selected-language model when adding server configuration or per-language settings. |
| Multiple terminal tabs and bottom/right placement | Terminal implementation belongs to the active work. Build-task configuration is a separate follow-on. |
| Independent tab groups and directional file drops | Pane/tab integration is owned there. Later nested-pane work starts from its delivered model. |
| Branch/stash and project/recent-project menus | Reconcile delivered menus before adding file history or broader navigation. |
| Agentic layout switching | Keep future agent review/context improvements separate from layout ownership. |
| Image presentation and tab/header polish | Further image capabilities remain later tasks. |

EXT-01 and EXT-05 have current source and fresh acceptance evidence. The other EXT tasks have implemented behavior and related passing journeys, with broader acceptance still open. Keep the remaining scope under the existing IDs rather than duplicating their implementations. The current integration owner for the baseline/native batch is this audit/roadmap thread; any new concurrent implementation must claim its files separately.

### Workstream boundaries

Use these likely paths when claiming work. They identify areas to coordinate, not files that every task must edit.

| Workstream | Primary paths | Shared integration |
| --- | --- | --- |
| Text and Unicode | `packages/zircon_text`, `packages/zircon_editor/src/navigation.zig`, `input.zig`, `display.zig`, Vim modules | Editor canvas and application edit propagation, currently affected by EXT work. |
| Persistence/recovery/watchers | `packages/zircon_workspace`, new owned filesystem/recovery services | `apps/zircon/src/actions.zig`, `projects.zig`, `shell.zig`, pane/session state. |
| Git | `packages/zircon_git`, `apps/zircon/src/services/git.zig`, `editor_git.zig` | Git views, shell/action dispatch and operation feedback. |
| Language/parser | `packages/zircon_language`, `services/language.zig`, `services/extension_host.zig`, `tools/zed-extension-host` | Completion/diagnostics/status UI, editor projections and selected-language state. |
| Search/index | `packages/zircon_search`, `services/search.zig`, `services/buffer_find.zig`, `project_index.zig` | Result views, shared file scopes and workspace edit publication. |
| Workspace/UI | `apps/zircon/src/panes.zig`, `view.zig`, `views`, `settings`, `commands.zig`, `key_bindings.zig` | Reserved EXT implementation first; integrate later UX work through one owner. |
| Terminal/tasks | `apps/zircon/src/terminal.zig`, then task configuration/service | Dock/pane state, process lifecycle and output navigation. Do not create competing terminal code. |
| Preview/agent | `packages/zircon_markdown`, `views/markdown.zig`, `packages/zircon_agent`, `services/agents.zig`, `views/agents.zig` | Shared document updates, rendering, permissions and EXT-07 layout. |
| Native/accessibility/rendering | `packages/zircon_ui/src/platform/macos`, `text`, `graphics`, `app` | Input/focus, window lifetime, terminal behavior and editor geometry. |
| Verification/distribution | `build.zig`, `tools`, `.github/workflows`, package/application tests | Any native tests sharing foreground access must run sequentially. |

## Working rules

1. Claim one checklist task or a small dependency chain before editing. Record owner, branch/workspace and likely shared files. Keep only one writer per file in a shared checkout.
2. Use a separate T3-managed checkout for concurrent implementation once more than one implementation is active. Existing dirty changes stay with their owner. Do not move, commit or overwrite another task's edits to make a checkout clean.
3. Treat `shell.zig`, `actions.zig`, `view.zig`, `panes.zig`, `commands.zig`, settings, the editor canvas, application tests and `build.zig` as integration areas. Separate package work can overlap only when its integration edits have a single owner.
4. Prefer a complete vertical slice. For example, external file notification must reach a buffer, its second view, LSP and visible conflict state. A watcher package alone does not finish the feature.
5. Preserve document identity, revision checks, atomic edits, dirty-buffer protection and existing extension rollback. New features use those mechanisms rather than bypassing them.
6. Run native UI tests sequentially. Record foreground and fallback routing separately. A cached native test run does not close a native input bug.
7. Each handoff names task IDs, commit/diff, files changed, actual commands/results, acceptance evidence and remaining limitations. Update the checkbox only after the integration owner verifies the result.
8. Update the checklist after each accepted slice. Keep the dated audit historical; correct current guides/status when behavior changes.

## Delivery sequence

| Milestone | Tasks | Exit condition |
| --- | --- | --- |
| M0: reconcile current work | EXT-01..08, BASE-01..03 | Current terminal/UI work is accounted for, overlapping ownership is explicit, fresh checks and a reproducible baseline exist. |
| M1: preserve files and input | BASE-04, TEXT-01..09, GIT-01..04, UX-04 | Recovery, disk/Git updates, Unicode editing and safe operations work together. Input/paint costs are measured and the reproduced dispatch failure is resolved. |
| M2: complete the coding loop | LANG-01..09, SEARCH-01..04, UX-01..03, UX-05..07, DEV-01 | Navigate, edit, format/refactor, search/replace, build and fix diagnostics inside the workspace. Core workflows are keyboard-accessible. |
| M3: complete review and polish performance | GIT-05..09, PERF-01..07, CONTENT-01, AGENT-01..02, EXTAPI-01..02, QA-01..03 | Partial staging/conflicts/history work; large/long sessions are measured; extension and agent review behavior is clear. |
| M4: broaden IDE/workspace capability | WORK-01..03, DEV-02..03, LANG-10, VIM-01..02, CONTENT-02..03, AGENT-03..04, EXTAPI-03 | More panes, debugger, remote work and richer editing/integrations have their own acceptance journeys. |
| M5: platform/product expansion | PLATFORM-01..03, COLLAB-01, DEV-04, AGENT-05, QA-04; optional GIT-10 and CONTENT-04 | Production distribution and selected broader parity work meet explicit support and operational requirements. |

Milestones are acceptance gates, not estimates or rigid serial barriers. Recovery can proceed while a language package is being designed. Existing terminal delivery can finish before M1. M1 should pass before declaring a dependable editor preview; M2 should pass before declaring the daily coding workflow complete. A public release also requires the applicable accessibility and distribution gates, even if some later features remain open.

### Recommended first work batch

| Order | Task | Why start here |
| --- | --- | --- |
| 1 | BASE-01 | Reconcile the active terminal/UI result and reserve integration files. Avoid rebuilding something already in flight. |
| 2 | BASE-02 | Make fresh native verification reproducible and preserve the existing input failure. |
| 3 | TEXT-01 | Diagnose and fix `TextDispatchFailed`; keep foreground/fallback evidence separate. |
| 4 | BASE-03 | Record frame/edit/Git/process counters before changing scheduling. |
| 5 | TEXT-05 | Add durable recovery for dirty and untitled buffers. This has direct data-loss value. |
| 6 | TEXT-07, then TEXT-06 | Define shared document-update delivery, then connect external file notifications and conflict handling. |
| 7 | GIT-01, then GIT-02 | Remove repository metadata work from ordinary typing and make external Git changes refresh baselines. |
| 8 | LANG-01 | Negotiate language-server synchronization and stop unconditional full-buffer updates. |

TEXT-03 grapheme work is an appropriate independent package task once ownership is established. Recovery, file watching and Git/LSP integration all touch workspace state; schedule their application integration rather than landing conflicting edits at once. The currently active UI work can continue throughout this batch under its existing ownership.

## Dependencies that determine the design

- TEXT-07 document changes connect external reloads, language services, views, search, preview and recovery. Define origin, captured revision, resulting revision, content identity and view mapping together.
- TEXT-04 async persistence must mark the captured content as saved. A later edit must remain dirty when an earlier save completes.
- TEXT-06 file watches and GIT-02 repository watches share event delivery, but their generations differ. Index changes can invalidate a gutter without a document edit.
- LANG-06 workspace edits and SEARCH-03 project replacement share transaction/publication requirements. Agree on all-or-nothing validation, dirty buffers, failure recovery and undo before separate implementations duplicate them.
- EXT-05 pane/tab changes affect document selection, close policy and session persistence. Recovery and later layouts must use the accepted pane model.
- EXT-04 terminal owns PTY/session behavior. DEV-01 adds task execution through that interface; it does not start a second terminal subsystem.
- BASE-04 operation state is shared by Git, downloads, LSP, saves, search and tasks. Keep a common visible status model without forcing unrelated operations into one serial queue.

## Verification and release gates

Use existing `check`, package suites, native journeys and real-server targets where they exercise the changed behavior. BASE-02 makes fresh native execution explicit. Add focused behavioral checks for risky boundaries such as recovery, file conflicts, workspace edits, protocol changes and process cancellation. Simple reversible presentation edits need appropriate layout/manual verification rather than tests that duplicate implementation details.

| Gate | Required evidence |
| --- | --- |
| File safety | Forced termination restores dirty and untitled text. Competing writes do not silently replace local edits. Async save completes against the right content state. |
| Input | Existing dispatch failure fixed; foreground/fallback paths pass; IME, clipboard, dead keys, shortcuts and grapheme operations checked across editor and fields. |
| Synchronization | External write/rename/delete/add/checkout updates the correct views, status and baselines; event storms and late results preserve local edits. |
| Coding workflow | Definition/refactor/format/project replace use current versions; build output navigates to a source diagnostic; one undo restores supported transaction scopes. |
| Git | Partially staged and unsaved changes remain distinguishable; hunk operations and conflict resolution preserve index/worktree correctness. |
| Performance | Reproducible release workload reports latency tails, UI blocked time, command/parse counts, process-tree memory and feature coverage. Proposed budgets are calibrated on named hardware. |
| Accessibility/OS | Primary flows work by keyboard; focus and text/control semantics pass targeted assistive-technology checks; supported scales and themes are readable. |
| Distribution | Packaged app includes required workers/resources, launches from a clean supported setup and meets the chosen signing/notarization/update policy. |

No percentage or calendar completion estimate is assigned. Package-sized tasks and changes to core editing protocols have different uncertainty. After BASE-01 and the first acceptance batch, estimate the next batch using actual scope and measured integration cost.

## Task handoff template

```text
Task IDs:
Owner and workspace/branch:
Starting commit and existing changes to preserve:
User-visible result:
Dependencies already verified:
Files/modules expected to change:
Acceptance commands and journey:
Evidence after implementation:
Remaining limits or follow-up IDs:
```

When starting a task, read its checklist entry and the relevant audit section, verify the dependencies still match current source, then implement and demonstrate that slice. Do not turn the entire roadmap into one large rewrite.
