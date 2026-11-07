# Editor, framework and platform delivery

Started 2026-11-07. This program implements the [source-backed recommendations](../research/zed-gpui-actions-2026-11-07.md), a smaller documented UI syntax, and native Linux and Windows support. The [editor checklist](../editor-todo.md) remains the task-status record. Decisions and evidence are recorded in [the decision log](../progress/editor-platform-decisions.tsv).

## Definition of done

There is no self-assigned quality score. Each area passes demonstrated behavior on supported systems. Compilation alone does not establish native platform support.

| Area | Acceptance gate |
| --- | --- |
| File safety | Forced termination restores saved and untitled work. Disk conflicts, explicit discard, partial/corrupt checkpoints and two windows preserve the correct bytes. |
| Document changes | Typing, undo, completion, reload, formatting and project edits publish ordered identity/revision/content-state changes to all views and consumers. |
| Language services | Capability-aware synchronization, persistent/incremental parsing, definition and return navigation, current diagnostics, formatting and validated workspace edits work with fixtures and real supported servers. |
| Input | Grapheme movement/deletion, clipboard, native IME, keyboard layouts, Vim and terminal focus preserve text and history. |
| Performance | Equivalent release workloads demonstrate bounded foreground work, latest-result freshness, process lifecycle and resource behavior. No comparative speed claim without a controlled Zed run. |
| Framework API | Shorter caller syntax preserves const rendering, generational ownership, safe callbacks, snapshots, layout validation and failed-frame rollback. Examples compile and document the supported contract. |
| Interaction/accessibility | Context shortcuts, lists, menus, dialogs and primary workflows have keyboard focus and real platform accessibility semantics. Failed frames retain the previous semantic tree. |
| Coding workflow | Project search/replace, file operations, build/test output navigation, hunk staging and conflict handling operate on the right buffer/disk/index identities. |
| Platforms | Native macOS, Linux and Windows windows render real text/scenes, accept native input, run the event loop and workers, support clipboard/dialogs and package required resources. Platform-specific verification records unsupported behavior explicitly. |
| Documentation/distribution | Public APIs, examples, platform requirements, feature limits, recovery policy and reproducible checks match the implementation. Packaged editor launches from a clean supported setup. |

## Order of work

1. Establish baseline and finish TEXT-05 recovery through startup, checkpointing and restore. Reuse the existing checkpoint format; test actual process termination.
2. Extend the existing edit-outcome path for TEXT-07. Connect async persistence, file/repository changes and dependent service invalidation.
3. Deliver GIT-01, LANG-01/02/03 and PERF-01 as separate measured changes. Keep full-reference fallbacks and stale-result protection.
4. Deliver TEXT-02/03, UX-03/04/05, LANG-04/07, then shared transactions and the remaining local coding-loop tasks. Accessibility semantics start at the element boundary.
5. Compare two UI API designs at real call sites. Choose the smaller understandable syntax, migrate examples and consumers, and document ownership and failure behavior with executable examples. Avoid a second permanent API for the same operation.
6. Implement common native platform seams and native Linux/Windows adapters using the [native platform plan](native-platforms.md). Platform support is part of this program, not satisfied by portable tests. Add target builds early to expose POSIX/macOS assumptions, then platform execution and packaging checks.
7. Run the complete coding journey and lifecycle/failure checks. Resolve findings and document the verified scope.

Units can overlap only at independent boundaries. Native tests that need foreground access run sequentially. Existing documentation changes belong to their current author and remain intact.

## Architecture constraints to preserve

- Non-owning generational entity handles, explicit scopes, scoped borrows and pointer-free read results.
- Const render and a platform-neutral frame/scene representation.
- All fallible staging before CPU frame commit. Handlers, focus, IME and accessibility publish with the same successful frame.
- Background jobs read retained immutable inputs. Completion resolves current owner/document/config identities before publication.
- Domain packages remain usable without native UI. Platform types stay behind the platform interface.
- Native text shaping/rendering and input share geometry and encoding rules. Fixed-width headless metrics never count as native text support.

## Baseline and current work

Starting commit is `560dc2a9d9111012ebfa93fb2243515ac5339753`, plus pre-existing documentation changes. `./tools/zig build check --summary all` passed all 32 steps on 2026-11-07. Cached suites are reported as cached; the 187 executed checks do not represent the total suite inventory.

TEXT-05 [application recovery](../progress/2026-11-07-recovery-integration.md) is delivered in `c4ce46e`. The [compact UI syntax](ui-syntax.md) adds eager tuple composition and typed callback inference with compiled documentation. Independent design/review readers inherit the session model; model diversity is reduced and the unconfigured different-family arena judge is omitted. Passing tests do not substitute for required independent implementation review.

Shared document-change delivery is now the next editor integration foundation. The workspace exposes an ordered `DocumentChange` value with document identity, before/after revision, content-state identity, edit mappings and typed origin. Shell editor input, completion, search replacement and command edits publish copied events into one UI-owned queue, with explicit count/origin inspection and disposal. Language, Git and recovery still need to consume the queue and the remaining edit origins need migration. Linux/Windows backend designs are grounded against native source and primary dependency APIs. Linux can now be exercised in a disposable Docker Desktop environment. Windows target compilation currently exposes POSIX permission assumptions and native Windows execution remains unverified.

Later slices retain their original checklist status until their acceptance gate passes. Linux and Windows execution availability must be established before claiming those platforms verified.
