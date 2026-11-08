# Editing and language workflow audit

Result: **ISSUES**. Core editing has substantial working coverage, but the language workflow is incomplete and completion application has two confirmed correctness defects.

Audited Zircon revision: `716dfdbbfcac76d75493fe5c477d717d4c37641c`. Compared with Zed upstream `b5cd310b3b54dfc659fcc06453e6358843dfe216` through the [primary-source reference report](../../research/zed-workflows-reference-2026-11-08.md). Installed Zed Preview is a separate version and was not driven by this audit worker.

This worker changed no production code and did not run native builds or drive desktop windows. Tests use the portable UI module and hidden headless app windows. Existing tests and new adversarial scenarios are reported separately. A passing installed-clangd test from the parent audit covers its server's explicit `textEdit` completion shape; it does not cover every valid completion shape.

## Confirmed defects

| Priority | Trigger and observed result | Cause and source | Acceptance criterion |
| --- | --- | --- | --- |
| P1 | Complete `pri` with a valid item containing `label = print`, `insertText = print`, no `textEdit`. Actual buffer is `priprint`. | [language.zig](../../../apps/zircon/src/services/language.zig), line 351, uses an empty cursor range for the fallback. It never derives the current completion word range. | Complete partial identifiers correctly when the server supplies only `label` or `insertText`; test beginning, middle and end of identifiers and Unicode boundaries. |
| P1 | Accept a completion with its main replacement on line 2 and an `additionalTextEdits` import at the start of the file. Actual state has 2 carets. Primary caret is offset 10 after the import, while the completion ends at offset 34. | [language.zig](../../../apps/zircon/src/services/language.zig), lines 351-358, sends all edits through [Editor.applyEdits](../../../packages/zircon_editor/src/editor.zig), lines 252-259. That general editing operation creates a caret per edit and normalizes the first one as primary. | Apply additional edits in the same undo transaction while retaining the intended completion caret. Typing immediately afterward must affect only the completed expression. |
| P2 | Open `main.zig`, split right, Save As `copy.rs` from the secondary pane. Actual primary language is `rust`; live secondary remains `zig`. | [actions.zig](../../../apps/zircon/src/actions.zig), lines 681-689, configures and synchronizes only `tabs[index].editor`, even though Save As changes the shared document path. | Rebind every live and retained view of that document, invalidate obsolete grammar/session results, and retain deliberate language overrides according to an explicit policy. |
| P2 | Open a clean `main.txt` containing `one`; externally write `two`; run ordinary shell polling and app steps. Editor remains `one`. | [project.zig](../../../apps/zircon/src/services/project.zig), lines 8-35, watches root/disclosed directory metadata, not open-file contents. [Shell.pollLanguage](../../../apps/zircon/src/shell.zig), line 701 onward, has no general content reload. [reloadClean](../../../packages/zircon_workspace/src/root.zig), line 216, is called from the Git worktree-mutation completion path and retired agent code, not normal file observation. | Reload externally modified clean buffers, preserve dirty buffers with a conflict choice, and notify all consumers through document changes. The existing save conflict check prevents silently overwriting changed disk contents, but does not refresh the visible editor. |

All four scenarios failed twice in fresh direct test executions with the same observed values. The harness injects valid owned completion messages into the real application acceptance handler. It exercises application edits and selection state, rather than reimplementing the algorithm. It is not a test of a particular server's output or a claim that every server emits the affected item shapes.

## Feature coverage against Zed

“Implemented” below means source and relevant existing coverage were inspected. It does not mean complete Zed parity or that every combination was tested during this audit.

| Workflow | Current Zircon behavior | Remaining work |
| --- | --- | --- |
| File editing and history | Insert/delete, CRLF-aware movement, indentation/newline indentation, line duplication, clipboard, multiple cursors, undo/redo, atomic document transactions, split views and selection remapping. The fresh 49-test editor suite covers many of these. | Fix the application-level completion and split Save As defects above. Expand combinations around retained secondary states and changes arriving from other consumers. |
| Syntax highlighting | Built-in lexical fallback for Zig/Rust/JSON/Markdown, extension lexical profiles, and revision-bound grammar highlights from the extension worker. Unaffected grammar colors are mapped through typing while new highlights arrive. | Semantic tokens are absent. Grammar refresh submits the full source to the worker and debounces subsequent revisions by 80 ms. This is an implementation observation, not a measured latency or performance defect. Cross-language injection behavior and large real projects need acceptance testing. |
| Folding and wrapping | Soft-wrap has source/display mapping; indentation folding survives edits and find can reveal folded matches. | Folding derives regions from indentation and closing characters, not Tree-sitter or LSP folding ranges. It skips scanning buffers above 8 MiB. |
| Buffer find/replace | App-level literal/regex, case and whole-word options, queued navigation, Unicode ranges, regex replacement expansion and undo. | Search is limited to buffers up to 8 MiB. Selection-only search and search of editable Git projections are not equivalent to ordinary source-buffer find. The editor package's older README describes only its lower-level literal helper, so it understates the actual application feature. |
| Completion entry and UI | Ctrl-Space and typing `.` request LSP completion. Popup supports up/down, Enter, Escape and click, with 8 visible items near the caret. Session/URI/revision/caret identities reject stale results. | Requests ignore negotiated trigger characters and always send `triggerKind = 1`. No general identifier-typing suggestions, local filtering, fuzzy ranking, `sortText`/`filterText`, completion documentation/resolve, or continued refinement of incomplete lists. Editing after a request usually dismisses it as the caret moves. Tab inserts indentation rather than accepting the completion. |
| Completion protocol shapes | Ordinary `TextEdit` and `additionalTextEdits` are parsed; UTF-16 positions are converted against the captured source revision. | Snippet and insert/replace support are explicitly advertised false. Snippet items are rejected. `CompletionList.itemDefaults` is not interpreted. The two confirmed application defects affect otherwise supported forms. Capability negotiation makes non-support for snippets itself an intentional limitation, not a protocol violation. |
| Hover | Debounced pointer hover, keyboard symbol-info action, retained Markdown content, revision/session checks, dismissal on edit/navigation, clamped popup. Existing lifecycle test verifies Markdown presentation and dismissal. | No signature-help workflow. Real languages, long documentation, code links, popup interaction and multiple views need broader native acceptance. The package README incorrectly still says hover is unimplemented; current code supports it. |
| Navigation and refactoring | The command catalogue and client pending/message types contain completion and hover, plus server lifecycle and diagnostics handling. | No definition, type definition, implementation, references, rename, code actions, document/workspace symbols or call-hierarchy request/application workflow. These are feature gaps confirmed from both client dispatch and application commands, not broken buttons for features already implemented. |
| Formatting | Editing and persistence can apply transactions, and the document-change enum reserves `formatting`. | No LSP formatting request, external formatter workflow, format command or format-on-save setting/behavior. The enum value alone does not implement formatting. |
| Diagnostics | Push diagnostics are stored per document, validated against current identity/revision where supplied; status counts them. The main view renders up to 4 clickable messages for the active ordinary editor. Server popover shows up to 5 messages per document. | No editor squiggles, diagnostic scrollbar markers, complete navigable project diagnostics view, pull diagnostics or next/previous-diagnostic workflow. More diagnostics may be counted than can be read in current UI. Unversioned diagnostics are assigned the current tracked version; the README's “ignores unversioned diagnostics” claim is stale. |
| Server lifecycle | Persistent stdio clients, initialization/configuration, full/incremental synchronization, UTF-16 conversion, cancellation, server-scoped request identity, shutdown/kill, stderr bounds, and explicit restart/stop controls. Fresh 17-test protocol suite passes. | `didSave` is not implemented and client advertises it false. `client/registerCapability` is acknowledged without applying dynamic registrations. No semantic-token, workspace-edit, watched-file registration, or richer server status/progress workflow. Server compatibility needs tests beyond one fixture and installed clangd. |
| Encoding and Unicode | Source storage requires valid UTF-8 without NUL. Coordinates handle UTF-16, CR/LF/CRLF, surrogate pairs and UTF-8 boundaries. | UTF-16/legacy file decoding and encoding preservation are absent. Movement/deletion uses code points, not grapheme clusters; combined emoji/combining marks can be split by a movement/deletion. Full bidi editing is not established. Zed also has bidi limitations, so do not call its behavior universally correct. |
| Large files and lines | Workspace read/save limit is 64 MiB. Existing canvas tests preserve oversized source bytes. | Lines above 64 KiB display a limit notice rather than their text. Grammar, LSP and app buffer-find paths skip or reject above 8 MiB. These explicit limits prevent a claim of complete large-file editing. No comparative benchmark was run. |
| Daily editing conveniences | Comments, indentation, Vim subset, find and folds are available. | No automatic bracket/quote pairing or bracket-skip workflow was found in text insertion or app commands. Language-aware indentation, syntax-aware selection, inlay hints and richer snippets remain broader product work. |

Source owners for these observations:

- [Editor commands and input](../../../packages/zircon_editor/src/editor.zig), [keyboard handling](../../../packages/zircon_editor/src/input.zig), [syntax](../../../packages/zircon_editor/src/syntax.zig), [folding](../../../packages/zircon_editor/src/folding.zig), [canvas](../../../packages/zircon_editor/src/canvas.zig).
- [Language orchestration](../../../apps/zircon/src/services/language.zig), [transport/dispatch](../../../packages/zircon_language/src/client.zig), [message model](../../../packages/zircon_language/src/model.zig), [hover](../../../apps/zircon/src/services/symbol_hover.zig), [completion/diagnostic presentation](../../../apps/zircon/src/view.zig).
- [Find orchestration](../../../apps/zircon/src/services/buffer_find.zig), [find controls](../../../apps/zircon/src/views/buffer_find.zig), [application commands](../../../apps/zircon/src/commands.zig), [settings values](../../../apps/zircon/src/settings/store.zig).
- [Document file validation](../../../packages/zircon_workspace/src/root.zig), lines 290-292, [safe persistence](../../../packages/zircon_workspace/src/persistence.zig), [code-point boundaries](../../../packages/zircon_text/src/snapshot.zig), lines 108-123.

## Git integration qualification

The preliminary suspicion that Git-only source documents were absent from the tab-backed document set was rejected. `services/git.zig:238-270` opens them as hidden `primary = false` tabs. Ordinary LSP document polling therefore can register them.

Two narrower integration risks require a dedicated Git-view reproduction before being promoted to confirmed defects:

- Syntax refresh in `services/language.zig:401` selects only the regular active tab or secondary source document. Opening the project diff preserves the old active tab, while editing a different Git excerpt changes `git.editing.active`. Grammar refresh might therefore miss the currently edited Git document.
- Git command interception in `git_editing.zig:332-366` handles selected editing commands but leaves completion, hover and find to ordinary `actions.active`. That function resolves the ordinary source pane, not `git.editing.active`. A multi-file diff test should check document/caret identity for these language and search commands.

These observations are passed to the Git audit. They must not be generalized into “Git editing has no syntax or language registration.”

## Verification

- `./tools/zig build test-language test-editor --summary all` succeeded with cached test results.
- To ensure fresh execution, captured the exact compile argv with `./tools/zig build test-language test-editor --verbose`, removed `--listen=-`, and directly executed both `zig test` commands. **17 language tests and 49 editor tests passed freshly.** Full output: `/tmp/audit-editing-portable-fresh.log`.
- `./tools/zig build test-app --verbose -Dtest-filter='symbol information'` succeeded. Its portable test command was reused for the standalone repro root below.
- Standalone adversarial app harness: **0 passed, 4 failed**, twice. Logs: `/tmp/audit-editing-completion.log` and `/tmp/audit-editing-repeat.log`. All four failures are the intended assertions; no compile error or test infrastructure failure was counted as a product defect.
- Parent owns native tests and installed-clangd acceptance. This worker makes no independent native, OS IME, accessibility, visual-polish, or latency claim.

The comparison is strongest for observable edit state, protocol coverage and source ownership. Multi-language real-server acceptance, full foreground IME behavior, screen-reader behavior and performance remain open verification areas.

## Replaying the four adversarial scenarios

Save the Zig code below to `/tmp/audit-editing-completion.zig`. Regenerate the portable app build command, then substitute only its root module and remove the build server argument. Module dependencies remain the repository's actual application dependencies.

```sh
./tools/zig build test-app --verbose -Dtest-filter='symbol information' > /tmp/audit-editing-build.log 2>&1
python3 - <<'PY'
from pathlib import Path
import shlex, subprocess
for line in Path('/tmp/audit-editing-build.log').read_text().splitlines():
    if 'zig test ' not in line:
        continue
    argv = shlex.split(line.removeprefix('info(verbose): '))
    argv = [arg.replace('-Mroot=apps/zircon/tests/all.zig', '-Mroot=/tmp/audit-editing-completion.zig')
            for arg in argv if arg != '--listen=-']
    at = argv.index('--test-filter')
    del argv[at:at + 2]
    raise SystemExit(subprocess.run(argv).returncode)
raise SystemExit('portable app test command not found')
PY
```

The test source is retained here because `/tmp` paths are disposable. It intentionally asserts the desired behavior, so exit status 1 is expected on the audited revision.

```zig
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
const Ops = struct {
    fn seed(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        try tab.editor.setSelection(snapshot, .{ .start = snapshot.byteLen(), .end = snapshot.byteLen() });
        self.language.pending = .{ .document = tab.document, .session = 0, .request = 1, .revision = snapshot.revision(), .cursor = snapshot.byteLen() };
        self.language.completions = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .data = .{ .completion = .{ .id = 1, .uri = "file:///main.zig", .version = snapshot.revision(), .items = &.{.{ .label = "print", .insert_text = "print" }} } } };
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCompletion(&event, cx, 0);
        if (self.status_is_error) return error.CompletionRejected;
    }
    fn check(self: *const zircon.Shell) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        const actual = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer t.allocator.free(actual);
        std.debug.print("completion input=pri insertText=print actual={s}\n", .{actual});
        try t.expectEqualStrings("print", actual);
    }
};
test "completion without textEdit replaces current typed prefix" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "pri" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.seed, .{});
    try app.read(owner, Ops.check, .{});
}

const Save = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
        if (self.status_is_error) return error.CommandFailed;
    }
    fn setPath(input: *ui.controls.TextInput, cx: *ui.Context(ui.controls.TextInput)) !void {
        input.bytes.clearRetainingCapacity();
        try input.bytes.appendSlice(input.allocator, "copy.rs");
        input.cursor = input.bytes.items.len;
        input.anchor = input.cursor;
        input.revision +%= 1;
        cx.notify();
    }
    fn save(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        try command(self, cx, .split_right);
        try command(self, cx, .save_as);
        try cx.update(self.fields.?.workspace.path, setPath, .{});
        try command(self, cx, .submit_path);
    }
    fn check(self: *const zircon.Shell) !void {
        std.debug.print("save-as main.zig to copy.rs primary={s} secondary={s}\n", .{ @tagName(self.tabs.items[0].editor.language), @tagName(self.secondary.?.editor.language) });
        try t.expectEqual(.rust, self.tabs.items[0].editor.language);
        try t.expectEqual(.rust, self.secondary.?.editor.language);
    }
};
test "Save As rebinds the language of both editor panes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 42;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Save.save, .{});
    try app.read(owner, Save.check, .{});
}

const Additional = struct {
    fn complete(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = &self.tabs.items[0];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        const at = snapshot.byteLen();
        try tab.editor.setSelection(snapshot, .{ .start = at, .end = at });
        self.language.pending = .{ .document = tab.document, .session = 0, .request = 1, .revision = snapshot.revision(), .cursor = at };
        self.language.completions = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .data = .{ .completion = .{ .id = 1, .uri = "file:///main.zig", .version = snapshot.revision(), .items = &.{.{ .label = "print", .insert_text = "print", .text_edit = .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 3 } }, .new_text = "print" }, .additional_edits = &.{.{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } }, .new_text = "import x;\n" }} }} } } };
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCompletion(&event, cx, 0);
        if (self.status_is_error) return error.CompletionRejected;
    }
    fn check(self: *const zircon.Shell) !void {
        const tab = &self.tabs.items[0];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        std.debug.print("completion autoimport selections={d} primary={d} completionEnd={d}\n", .{tab.editor.selections.items.items.len, tab.editor.primary().head, snapshot.byteLen()});
        try t.expectEqual(@as(usize, 1), tab.editor.selections.items.items.len);
        try t.expectEqual(snapshot.byteLen(), tab.editor.primary().head);
    }
};
test "completion additional text edits keep one cursor at completion" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const something=1;\npri" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Additional.complete, .{});
    try app.read(owner, Additional.check, .{});
}

const External = struct {
    fn check(self: *const zircon.Shell) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[0].document);
        defer snapshot.deinit();
        const actual = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer t.allocator.free(actual);
        std.debug.print("external write expected=two editor={s}\n", .{actual});
        try t.expectEqualStrings("two", actual);
    }
};
test "clean editor reloads an external change during normal polling" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "one" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.txt"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "two" });
    for (0..4) |i| {
        try app.update(owner, zircon.Shell.pollLanguage, .{});
        _ = try app.step(@floatFromInt(i + 1));
    }
    try app.read(owner, External.check, .{});
}

```
