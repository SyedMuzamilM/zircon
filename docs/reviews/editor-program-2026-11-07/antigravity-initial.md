# Editor Program Review: Antigravity Initial Report

**Reviewer**: Antigravity (Gemini 3.8 Flash High)
**Date**: 2026-11-07
**Commit HEAD**: [`36e30a8150dd386f5a51cfe85a88d20751e65ea3`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`docs(editor): define evidence gates for autonomous parity work`)
**Previous Commit**: [`bad215247947b8c37933330e2f6cc0d4cbd645ef`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`fix(editor): preserve continuation indentation and gutter backgrounds`)
**Scope Inspected**: Actual current working tree (HEAD + 32 modified tracked files [+1337 / -233 lines] + 20 untracked files/directories)
**Status**: **ISSUES** (No 10/10 awarded; significant functional gaps, performance bottlenecks, and unverified runtime claims identified)

---

## 1. Scope, Method & Limitations

### 1.1 Review Method
This review was conducted as a clean, independent, read-only audit of the repository's actual code, tests, dirty diff, benchmark data, evidence captures, and decision records. In accordance with session constraints:
- **No sub-agents** were spawned.
- **No heavy native UI tests, benchmarks, or heavy build targets** were executed concurrently to avoid display interference or resource contention.
- **No application, configuration, or documentation files** outside this assigned report were modified.
- Source code claims were verified directly against implementations in [`apps/zircon/src/`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src) and [`packages/`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages), rather than relying on prior historical reports.

### 1.2 Working Tree State (Dirty Scope)
The checkout contains substantial uncommitted additions beyond commit [`36e30a8`](file:///Users/syedmuzamilm/work/expirements/zigpui):
- **32 Modified Tracked Files**:
  - Shell & Chrome: [`apps/zircon/src/shell.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig), [`views/chrome.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig), [`panes.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/panes.zig), [`actions.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig), [`commands.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/commands.zig), [`view.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig)
  - Settings & Themes: [`apps/zircon/src/settings/store.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/store.zig), [`apps/zircon/src/services/extensions.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/extensions.zig)
  - Services & Views: [`apps/zircon/src/services/language.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/language.zig), [`apps/zircon/src/views/image.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/image.zig), [`apps/zircon/src/views/git_controls.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/git_controls.zig), [`packages/zircon_editor/src/folding.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/folding.zig)
- **Key Untracked Files**:
  - Terminal subsystem: [`apps/zircon/src/terminal.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/terminal.zig)
  - Workspace controls & picker: [`apps/zircon/src/views/workspace_controls.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/workspace_controls.zig)
  - Recent projects store: [`apps/zircon/src/recent.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/recent.zig)
  - New SVG icons: [`packages/zircon_ui/src/controls/icons/branch.svg`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_ui/src/controls/icons/branch.svg), `language_server.svg`, `stash.svg`
  - Evidence & Benchmarks: [`docs/research/evidence/wrapping-2026-11-07/`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/research/evidence/wrapping-2026-11-07/), [`docs/benchmarks/editor-2026-11-07/`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/benchmarks/editor-2026-11-07/)

### 1.3 Environmental Constraints & Primary Sources
- **Pstack Context Limitation**: Access to external skill references at `/Users/syedmuzamilm/.codex/skills/pstack/...` was intercepted and blocked by the platform security policy (outside current active project workspace boundaries). The audit proceeded using repository-local primary sources.
- **Primary Source References**:
  - [`docs/reviews/editor-program-2026-11-07/plan.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/plan.md)
  - [`docs/reviews/editor-program-2026-11-07/starting-state.json`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/starting-state.json)
  - [`docs/reviews/editor-program-2026-11-07/reference-inspection.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/reference-inspection.md)
  - [`docs/reviews/editor-program-2026-11-07/decisions.tsv`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/decisions.tsv)
  - [`docs/editor-todo.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/editor-todo.md)
  - [`docs/benchmarks/editor-2026-11-07/README.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/benchmarks/editor-2026-11-07/README.md)
  - [`docs/research/zircon-vs-zed-audit-2026-11-06.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/research/zircon-vs-zed-audit-2026-11-06.md)
  - [`docs/reviews/zed-ui/rubric.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/rubric.md) & [`inspection.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/inspection.md)

---

## 2. Reference Baseline & Evidence Audit

### 2.1 Installed Zed Reference Verification
- **Binary**: Zed Preview 1.28.0 (build `20261104.153513`) installed at `/Applications/Zed Preview.app/Contents/MacOS/zed`.
- **SHA-256 Hash**: `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637`.
- **Finding on Capture Quality**: As documented in [`docs/reviews/editor-program-2026-11-07/reference-inspection.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/reference-inspection.md), the capture `zed-light-trust-dialog.png` (PID 7964) is **invalid as clean-editor parity evidence**. The main editor window was completely obscured by an un-dismissed modal "Do you trust the authors of the files in this window?" security prompt. Furthermore, the window was captured at 1470 × 923 instead of the standardized 1240 × 820 canvas, and AX API accessibility automation was unable to focus or dismiss the dialog.
- **Historical UI Reviews**: Prior reviews claiming high scores (e.g. 10/10) cannot be accepted as proof of current parity. Those captures either used historical builds or omitted native window chrome comparisons.

---

## 3. Audit of `decisions.tsv` & Attention Flags

An audit of [`docs/reviews/editor-program-2026-11-07/decisions.tsv`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/decisions.tsv) reveals multiple critical discrepancies and unsupported claims:

| Timestamp | Topic | Decision | Logged Result | Audit Finding |
|---|---|---|---|---|
| `2026-11-07T03:55:00Z` | `frame` | Capture clean native AppKit frame via test harness without window controls | `open` | **PASS (Fact)**: Well-supported. AppKit test harness captures client area (`MTKView`), which legitimately excludes WindowServer titlebar buttons. |
| `2026-11-07T04:19:15.361643Z` | `rendering` | Commit verified wrapping and gutter fixes to provide concrete first step | `45 editor and 92 native checks passed` | **ATTENTION FLAG (Unsupported / Anomaly)**: See details below. |
| `2026-11-07T04:19:15.361678Z` | `reference` | Reject trust-obscured capture as clean-editor parity evidence | `INCONCLUSIVE` | **PASS / ATTENTION FLAG**: Rejection is factually supported by inspection, but marking the result `INCONCLUSIVE` blurs a definitive rejection decision with the status of the capture. |

### Attention Flags for `decisions.tsv`:
1. **Timestamp Inversion vs Starting State**: Commit [`bad2152`](file:///Users/syedmuzamilm/work/expirements/zigpui) was recorded in [`starting-state.json`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/starting-state.json) at `04:19:15.351329Z`, which is *before* the TSV row timestamp `04:19:15.361643Z`.
2. **Evidence Citation Mismatch**: Row 2 cites [`reference-inspection.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/reference-inspection.md), but `reference-inspection.md` does *not* contain the wrapping and gutter verification results! The actual test results reside in [`docs/research/evidence/wrapping-2026-11-07/README.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/research/evidence/wrapping-2026-11-07/README.md).
3. **Selective Omission of Retained Failures**: While Row 2 notes that "45 editor and 92 native checks passed", it omits the fact that the underlying baseline service suite (`BASE-03`) suffered **6 failures** (4 grammar worker readiness timeouts and 2 `ServicesDidNotRun` failures) on the exact same commit base ([`docs/benchmarks/editor-2026-11-07/README.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/benchmarks/editor-2026-11-07/README.md)).
4. **Omission of Dirty State Decisions**: Only 3 decisions are recorded in `decisions.tsv`. There are zero decisions tracking the substantial pre-existing dirty working tree changes (two-pane tabs, terminal emulator, language picker, recent projects, image viewer zoom).

---

## 4. Evaluation Across All Plan Dimensions

Scores are evaluated strictly against parity with installed Zed Preview 1.28.0. Dimensions lacking verified automated runtime proof are marked **UNVERIFIED**.

| Dimension | Score / Status | Assessment Summary |
|---|---|---|
| **1. UI/Workflow Fidelity** | **5 / 10** | Two pane groups (`primary` and `secondary`) with drag-and-drop tabs exist in dirty diff, but arbitrary pane trees (`WORK-01`) and dock panels are missing. Status bar diagnostics and language picker popup are present, but modal keyboard focus and breadcrumb navigation are incomplete. |
| **2. Correctness & Data Safety** | **6 / 10** | Piece-tree CRDT buffer and atomic file saves with sync/replace are sound. However, switching languages in [`workspace_controls.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/workspace_controls.zig#L48) destructively tears down all language servers across all open documents. Terminal process teardown uses raw SIGKILL. |
| **3. Text / IME / Unicode** | **6 / 10** | Basic UTF-8 line/column indexing and navigation work. However, grapheme cluster navigation (multi-codepoint emoji, accented characters) is partial, and IME foreground composition dispatch has historical character duplication issues. |
| **4. Performance & Memory** | **4 / 10** | Core typing on small buffers is responsive (20/20 benchmark passed). However, full-document re-scanning occurs synchronously on the UI thread for indentation folding (20.9 MB scanned for 20 keystrokes), soft-wrap row cache recomputes the entire buffer on edits, and full-buffer LSP serialization sends >21 MB across stdio. Baseline BASE-03 retained 6 failures. |
| **5. Settings, Fonts & Themes** | **5 / 10** | JSON settings store with atomic write and disk reload works. One Dark / One Light palettes exist. However, theme syntax tokens are flattened to only 7 generic classes (plain, keyword, string, number, comment, punctuation, builtin) vs Zed's full Tree-sitter scope palette. Vim bindings only support single-character remaps. |
| **6. Extensions & Language Support** | **4 / 10** | Stdio JSON-RPC client supports `didOpen`, `didChange`, and `completion`. However, synchronization is strictly full-buffer (`didChange` full sync), grammar worker pipes suffer intermittent timeouts (4/20 failures), and core language navigation (Definition, References, Hover, Rename, Code Actions, Formatting) is completely unimplemented. |
| **7. Vim & Keybindings** | **4 / 10** | Normal, Insert, Visual, VisualLine, VisualBlock, counts, operators (`d`, `c`, `y`, `p`), search (`/`), and dot repeat exist. However, there are no named registers (single register only), no macros (`q`), no marks (`m`), no Ex commands (`:`), and no multi-key chords. |
| **8. API & Function Design** | **6 / 10** | Clear separation of modular packages (`zircon_text`, `zircon_editor`, `zircon_ui`, `zircon_language`, `zircon_workspace`). However, `lsp.Client` is tightly coupled to child process stdio pipes, lacks rich LSP types, and mixes memory allocators (`page_allocator` vs `self.allocator`). |
| **9. Formatting & Documentation** | **6 / 10** | Architecture guides and research audits are extensive. However, several documents are stale regarding soft-wrap and terminal support, and public module contracts lack comprehensive doc comments. |
| **10. Verification & Distribution** | **UNVERIFIED** | While headless editor unit checks (45) and native rendering checks (92) pass, full service workload verification is blocked by 6 retained benchmark failures (BASE-03), and native UI tests cannot run concurrently without display isolation. |

---

## 5. Top 10 Actionable Findings (ISSUES)

### Finding 1: Language Server Teardown on Language Switch Drops All Sessions Globally
- **Location**: [`apps/zircon/src/views/workspace_controls.zig:48`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/workspace_controls.zig#L48)
- **Status**: **ISSUES**
- **Trigger**: User selects a language from the language picker popup (`choose()` in `workspace_controls.zig`).
- **Impact**: `self.language.deinit(self.allocator)` is invoked, terminating *every* active language server process across all open tabs, discarding all diagnostics, and incrementing generation. Unrelated open documents (e.g. an open Zig or Rust file) immediately lose their LSP connection and diagnostics without re-opening.
- **Evidence**:
  ```zig
  // apps/zircon/src/views/workspace_controls.zig:48
  self.language.deinit(self.allocator);
  self.popup = .none;
  ```
- **Implementation Boundary & User Journey**: User working in a multi-file project opens a `.txt` scratchpad and switches its language to JSON; immediately, all error squiggles and auto-completion in their primary Zig workspace disappear because the language server was killed.
- **Smallest Corrective Direction**: Reconcile only the target document's session: send `textDocument/didClose` to the old server and register with the new server, preserving unrelated running sessions in `self.language.sessions`.
- **Acceptance Check**: Changing the language of tab 1 leaves tab 2's LSP process alive, with diagnostics and completion requests continuing to function without interruption.

---

### Finding 2: Full-Buffer Serialization on Every Keystroke in LSP Synchronization
- **Location**: [`packages/zircon_language/src/client.zig:104-108`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_language/src/client.zig#L104-L108)
- **Status**: **ISSUES**
- **Trigger**: Any edit made in a document associated with an active language server (`Client.didChange`).
- **Impact**: LSP synchronization is strictly full-buffer (`textDocument/didChange` sending `snapshot.copy(0..byteLen)` as a single replacement). For a 1 MiB file, 20 edits transfer over 21 MB of JSON-RPC text across stdio pipes, creating massive IPC and memory allocation overhead.
- **Evidence**:
  ```zig
  // packages/zircon_language/src/client.zig:104-108
  const bytes = try snapshot.copy(self.allocator, .{ .start = 0, .end = snapshot.byteLen() });
  defer self.allocator.free(bytes);
  try self.enqueue(.{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{
      .textDocument = .{ .uri = uri, .version = snapshot.revision() },
      .contentChanges = [_]struct { text: []const u8 }{.{ .text = bytes }},
  } });
  ```
  Confirmed by benchmark baseline in [`docs/benchmarks/editor-2026-11-07/README.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/benchmarks/editor-2026-11-07/README.md): *"LSP queued framed bytes, 1 MiB: 21,216,901–21,216,921 bytes"*.
- **Implementation Boundary & User Journey**: In large files (>10,000 lines), rapid typing causes LSP child process queues to spike and CPU usage to surge as multi-megabyte payloads are encoded and piped on every keypress.
- **Smallest Corrective Direction**: Implement incremental `textDocument/didChange` support utilizing the editor's existing `text.Change` ranges (`range: {start, end}` and replacement slice).
- **Acceptance Check**: 20 consecutive single-character edits in a 1 MiB buffer queue less than 50 KB of total JSON-RPC payload across stdio instead of >20 MB.

---

### Finding 3: Indentation Folding Synchronously Scans Full Buffer on UI Thread During Paint
- **Location**: [`packages/zircon_editor/src/folding.zig:20-23`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/folding.zig#L20-L23)
- **Status**: **ISSUES**
- **Trigger**: User types or edits in an editor with folding enabled (`State.ensure`).
- **Impact**: Whenever the document revision changes, `ensure()` copies the entire document text into a newly allocated buffer (`snapshot.copy(a, ...)`), splits across all newlines, and scans line indentations synchronously on the UI thread during layout/paint preparation.
- **Evidence**:
  ```zig
  // packages/zircon_editor/src/folding.zig:20-23
  if (snapshot.byteLen() <= 8 * 1024 * 1024) {
      const source = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
      self.scanned_bytes +%= source.len;
      defer a.free(source);
  ```
  Baseline benchmark records: *"Folding scanned bytes, 1 MiB: 20,971,530 bytes"* across 20 keystrokes.
- **Implementation Boundary & User Journey**: Editing near the top of an 8 MiB file stutters the main thread as 8 MB is allocated and scanned on every character before the frame can render.
- **Smallest Corrective Direction**: Compute folding ranges lazily for visible viewport rows, or offload full-document AST/indentation folding scans to a background thread worker.
- **Acceptance Check**: Editing a 5 MiB file does not allocate 5 MiB or scan the whole buffer synchronously within `State.ensure` on the UI thread during prepaint.

---

### Finding 4: Language Client Lacks Core Code Navigation & Code Action Methods
- **Location**: [`packages/zircon_language/src/client.zig:118`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_language/src/client.zig#L118) & [`apps/zircon/src/services/language.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/language.zig)
- **Status**: **ISSUES**
- **Trigger**: User requests "Go to Definition", "Find References", "Hover", "Rename Symbol", or "Code Actions".
- **Impact**: Zircon's `lsp.Client` only defines `initialize`, `didOpen`, `didChange`, `didClose`, and `completion`. Primary code navigation features present in Zed Preview are completely absent from the client protocol and UI.
- **Evidence**: Protocol methods in `client.zig` are strictly limited to completion. Open tasks in [`docs/editor-todo.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/editor-todo.md): `LANG-04` (definition), `LANG-05` (references), `LANG-06` (hover), `LANG-07` (rename), `LANG-08` (code actions).
- **Implementation Boundary & User Journey**: A developer pressing `Cmd-Click` or typing `gd` in Vim normal mode receives no action, forcing manual file search.
- **Smallest Corrective Direction**: Implement `textDocument/definition` in `lsp.Client`, deserialize `Location` / `LocationLink`, and hook into editor jump history navigation.
- **Acceptance Check**: Calling `client.definition()` emits a JSON-RPC request and returns the target URI and position; editor opens target file and positions cursor on symbol.

---

### Finding 5: Theme Syntax Tokens Restricted to 7 Generic Classes vs Full Tree-Sitter Highlighting
- **Location**: [`apps/zircon/src/services/extensions.zig:33`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/extensions.zig#L33) & [`packages/zircon_editor/src/theme.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/theme.zig)
- **Status**: **ISSUES**
- **Trigger**: Activating any theme (e.g. One Dark, One Light).
- **Impact**: Syntax highlight tokens are flattened to exactly 7 categories: `plain`, `keyword`, `string`, `number`, `comment`, `punctuation`, and `builtin`. Rich Tree-sitter capture scopes supported by Zed Preview (functions, methods, types, constants, variables, attributes, docstrings, lifetimes, operators) are discarded or collapsed.
- **Evidence**:
  ```zig
  // apps/zircon/src/services/extensions.zig:33
  .tokens = .{
      color(contribution.syntax.plain), color(contribution.syntax.keyword),
      color(contribution.syntax.string), color(contribution.syntax.number),
      color(contribution.syntax.comment), color(contribution.syntax.punctuation),
      color(contribution.syntax.builtin),
  }
  ```
- **Implementation Boundary & User Journey**: Switching themes in Zircon leaves code looking flat and monotone compared to Zed Preview, with struct types, function calls, and variable bindings rendered in uniform text color.
- **Smallest Corrective Direction**: Expand `Theme.tokens` to support standard Tree-sitter scopes (`function`, `type`, `constant`, `variable`, `operator`, `property`, `attribute`) and map theme contributions to this expanded array.
- **Acceptance Check**: Rust and Zig files display distinct colors for function declarations, type annotations, and local variables under One Dark.

---

### Finding 6: Vim Mode Lacks Named Registers, Macros, Marks, and Multi-Key Chords
- **Location**: [`packages/zircon_editor/src/vim.zig:25`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/vim.zig#L25) & [`apps/zircon/src/settings/store.zig:176`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/store.zig#L176)
- **Status**: **ISSUES**
- **Trigger**: User attempts standard Vim workflows: `"ayy`, `"ap`, `qa...q`, `ma`, `'a`, or configures key remaps such as `jk` -> `<Esc>`.
- **Impact**: `State` holds only a single unnamed `register: []u8`, no macro recording buffer, no mark registry, and `parseVimBindings` rejects any binding where `key.len != 1` or `value.len != 1`.
- **Evidence**:
  ```zig
  // apps/zircon/src/settings/store.zig:176
  if (entry.key_ptr.len != 1 or entry.key_ptr.*[0] < 32 or entry.key_ptr.*[0] >= 127 or
      entry.value_ptr.* != .string or entry.value_ptr.string.len != 1) return error.InvalidKeyBindings;
  ```
- **Implementation Boundary & User Journey**: Vim users cannot use multiple clipboards, replay repetitive actions via macros, jump across marks, or map common multi-key escape chords.
- **Smallest Corrective Direction**: Introduce a 26-register map `[26][]u8` + system clipboard registers (`*`/`+`), add a 2-key sequence buffer for chord resolution in `vim.zig`, and support standard key escape names in settings.
- **Acceptance Check**: `"aY` yanks to register `a`, `"ap` pastes register `a` without overwriting the unnamed register, and setting `"jk": "escape"` exits insert mode cleanly.

---

### Finding 7: Darwin-Hardcoded Terminal Implementation with Magic Numbers
- **Location**: [`apps/zircon/src/terminal.zig:18, 86, 276`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/terminal.zig#L18)
- **Status**: **ISSUES**
- **Trigger**: Compiling or running Zircon on Linux or non-macOS systems.
- **Impact**: `terminal.zig` references Darwin-only `_NSGetEnviron()`, hardcodes macOS Darwin ioctls (`0x20007461` for `TIOCSCTTY` and `0x80087467` for `TIOCSWINSZ`), and lacks portable PTY support. On Linux, this will fail compilation or produce runtime errors.
- **Evidence**:
  ```zig
  // apps/zircon/src/terminal.zig:18, 86, 276
  extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
  _ = ioctl(slave, @as(c_ulong, 0x20007461), @as(c_int, 0)); // TIOCSCTTY on macOS
  _ = ioctl(self.fd, @as(c_ulong, 0x80087467), &size);       // TIOCSWINSZ on macOS
  ```
- **Implementation Boundary & User Journey**: Building Zircon on a Linux workstation fails at compile time due to missing `_NSGetEnviron`, breaking cross-platform parity.
- **Smallest Corrective Direction**: Guard Darwin-specific PTY code behind `builtin.os.tag == .macos`, supply standard Linux POSIX equivalents (`environ`, `<asm/ioctls.h>` constants), and abstract the PTY layer.
- **Acceptance Check**: Terminal subsystem compiles cleanly on both macOS and Linux targets.

---

### Finding 8: Secondary Split Pane Excluded from Language Service Poll Reconciliation
- **Location**: [`apps/zircon/src/services/language.zig:112`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/language.zig#L112)
- **Status**: **ISSUES**
- **Trigger**: Opening a document exclusively in the secondary split pane (`self.secondary`).
- **Impact**: `services/language.zig:112` reconciles documents by iterating strictly over `for (self.tabs.items) |tab|`. If a tab is secondary-only (`tab.primary == false`), or if secondary holds a split view whose tab state is detached, `poll()` bypasses it, failing to send `didOpen` and leaving the file without LSP diagnostics or completions.
- **Evidence**:
  ```zig
  // apps/zircon/src/services/language.zig:112
  for (self.tabs.items) |tab| {
      const record = try self.workspace.getConst(tab.document);
      const path = record.path orelse continue;
      // ... registers doc with LSP session
  }
  ```
- **Implementation Boundary & User Journey**: User splits editor into two panes to view a header and implementation side-by-side; the right pane fails to receive auto-completion or diagnostic highlights.
- **Smallest Corrective Direction**: Include `self.secondary`'s active document in the reconciliation set within `poll()`.
- **Acceptance Check**: Opening a code file in the secondary split pane triggers `textDocument/didOpen` and displays language diagnostics.

---

### Finding 9: Soft-Wrap Cache Full-Document Row Recomputation on Edits
- **Location**: [`packages/zircon_editor/src/wrap.zig:75`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/wrap.zig#L75)
- **Status**: **ISSUES**
- **Trigger**: Typing into a soft-wrapped document (`soft_wrap != .none`).
- **Impact**: `Cache.rebuild()` iterates over the entire document from byte 0 to `snapshot.byteLen()`, calculating display rows across all lines. While commit `bad2152` corrected indentation and gutter backgrounds, editing performance in large wrapped files scales with total buffer size rather than edit size.
- **Evidence**: Documented in [`docs/benchmarks/editor-2026-11-07/README.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/benchmarks/editor-2026-11-07/README.md): *"Soft-wrap row recomputation is a known hotspot"*.
- **Implementation Boundary & User Journey**: In a 5,000-line Markdown or text file with soft wrap enabled, each keystroke incurs noticeable typing latency due to synchronous full-buffer wrap row rebuilding.
- **Smallest Corrective Direction**: Implement line-incremental wrap caching that recomputes only modified lines and adjusts subsequent row offsets.
- **Acceptance Check**: Typing in line 100 of a 5,000-line wrapped document re-wraps only line 100 without traversing the remaining lines.

---

### Finding 10: Git Subsystem Status Checks Lack Debouncing on Keystroke / Save
- **Location**: [`apps/zircon/src/actions.zig:540`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig#L540) & [`apps/zircon/src/services/git.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/git.zig)
- **Status**: **ISSUES**
- **Trigger**: Rapid file saves or branch switching.
- **Impact**: Actions directly call `@import("services/git.zig").start(self, cx, .refresh)` without a debounce window. In repositories with large working trees, repeated git status subprocess spawns create CPU spikes and UI micro-stutters.
- **Evidence**: Actions throughout `actions.zig` invoke git operations synchronously upon menu or command triggers without rate-limiting.
- **Implementation Boundary & User Journey**: Rapidly saving files or staging changes in a large repository causes UI sluggishness while child git processes run.
- **Smallest Corrective Direction**: Add a 250ms debouncing timer to Git status refreshes following file saves.
- **Acceptance Check**: Five rapid file saves within one second trigger at most one background `git status` invocation.

---

## 6. What a Full Score (10/10) Would Still Require

To honestly achieve full parity with installed Zed Preview 1.28.0, the following verifiable milestones must be reached:

1. **Window Layout & Arbitrary Pane Trees (`WORK-01`)**:
   - Replace the two-pane hardcoded model with an arbitrary recursive split tree supporting dockable, resizable panels on all four edges.
2. **Language Protocol Parity (`LANG-04` through `LANG-08`)**:
   - Implement incremental synchronization (`didChange` delta ranges).
   - Implement Definition, References, Hover popover, Rename Symbol, Code Actions, and Document Formatting.
3. **Syntax Highlighting & Grammar Stability (`LANG-02`, `EXTAPI-02`)**:
   - Eliminate pipe timeouts in grammar worker processes (resolve the 4/20 failures in BASE-03).
   - Expand the syntax token palette from 7 generic classes to the full Tree-sitter scope set (functions, types, constants, variables, operators, properties).
4. **Vim Emulation Depth (`VIM-01`, `VIM-02`)**:
   - Support 26 named registers, macro recording/replay (`q`), marks (`m`), and multi-key chord mappings in settings.
5. **UI-Thread Performance Decoupling (`PERF-01`, `PERF-02`)**:
   - Replace full-buffer scans in indentation folding and soft-wrap cache with incremental / lazy viewport algorithms.
6. **Clean Parity Evidence**:
   - Capture a clean, unobstructed native AppKit window of Zed Preview 1.28.0 (Light and Dark) matching exact bounds (1240 × 820) with no modal trust dialogs.
   - Achieve 40/40 passing runs on the BASE-03 benchmark workload with zero retained timeouts or worker failures.
