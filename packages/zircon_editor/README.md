# Zircon editor package

Editor state and a custom canvas built on `zircon_text` and `zircon_ui`. The package imports no platform modules. A shell owns documents and decides tabs/files; each `Editor` owns its selections, scrolling, lexical cache and selection-history metadata.

```zig
var state = try editor.Editor.init(allocator);
defer state.deinit();
state.language = editor.syntax.languageForPath(path);
var snapshot = document.snapshot();
defer snapshot.deinit();
state.synchronize(snapshot);
const canvas = try state.render(&document, builder);
// Attach a keyed, focusable Ui.listen handler. In that handler:
var outcome = try state.handle(&document, event);
defer if (outcome.change) |*change| change.deinit();
```

`handle` returns `Outcome{handled,change,reset}`. Notify the shell entity when handled. Map other views of the same document through `mapChange` before destroying `change`; on undo/redo `reset` means those views must `synchronize` against the new snapshot. Call `synchronize` after opening a document, changing its language, or applying external changes. Direct document access remains callback-scoped; a canvas retains only an immutable snapshot.

`execute` supports insert/delete, code-point and word movement, line/document/page navigation, extended selections, select-all, indentation, newline indentation, line duplication, undo and redo. Local key handling adds clipboard, option-click multiple cursors, double/triple-click selection, dragging, Cmd/Ctrl-D occurrence selection and revisioned native composition. The shell handles application commands such as save/open/palette/find. Native vertical and pointer placement use injected glyph metrics and tab source/display mapping. Pure command movement uses byte columns as its documented fallback.

Ordinary typing shares a history group until navigation or another command. A marked composition uses one group; Escape undoes that group. Each batch edits normalized selections atomically through the document. History retains selection metadata for up to 1,024 content states; document history remains the authority for bytes. Output Change storage belongs to the caller. Internal selection/cache bookkeeping may grow before an edit fails; document contents and selections remain unchanged on allocation failure during insert.

The canvas paints visible logical rows plus overscan, gutter, active line, selections, lexical runs, search matches, composition underline, carets and a scroll thumb. It clips document content separately from the gutter. The frame retains a document root and copies visible line text and bounded native surrounding context. A large selected range can enlarge that context. The current policy displays a notice for a single logical line longer than 64 KiB rather than shaping it; the original bytes remain intact. Such lines need a future horizontal text-window policy before claiming complete large-line support.

Lexical highlighting covers Zig, Rust, JSON and Markdown. A cache stores per-line multiline-comment state and refreshes until the outgoing state converges after edits. This is lexical highlighting, not parsing, language intelligence or semantic tokens. Syntax-cache allocation failure falls back to plain text, retaining document correctness. Syntax work during initial load remains proportional to file text; rendering is bounded by visible lines.

`findNext` wraps literal search in either direction. `replaceAll` creates one undo transaction. Case-insensitive search uses the text package's ASCII folding policy. Movement is code-point safe and treats CRLF as one step; full grapheme segmentation, bidi selection geometry, soft wrapping and semantic language support are not implemented. Focused carets blink through the framework deadline scheduler and stop requesting ticks when unfocused. A full OS input-method journey remains an application verification task.

Run with Zig 0.17.1:

```sh
./tools/zig build --build-file packages/zircon_editor/build.zig test
./tools/zig build --build-file packages/zircon_editor/build.zig test-build -Dtarget=aarch64-linux-gnu
```

Tests exercise real document edits, multi-cursor mapping, grouped history, CRLF, composition, syntax invalidation, tab geometry, find/replace, committed framework canvas/input, bounded context, explicit long-line behavior and allocation-failure cleanup.

## Host contributions and decorations

`Theme` contains semantic editor and token colors. `language_profile` supplies immutable keyword/comment/string rules with `language = .custom`. The host retains their source generation; each committed canvas copies its profile into frame storage. This remains lexical highlighting, independent of the language-server process.

`git_changes` and `git_revision` attach source-revision-bound line markers. `setBlame` copies author/commit/summary data; `hideBlame` releases it. An inline blame block reserves vertical space, and `rowAt`, `rowY`, scrolling and caret reveal use the same mapping. Obsolete decorations do not affect a newer document revision. Repository commands and language-server transports belong to separate packages and the host.
