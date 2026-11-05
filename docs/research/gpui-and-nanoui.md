> Source research retained for reference. Implementation recommendations here predate the user-supplied framework specification; follow `docs/implementation-plan.md` for the current design. NanoUI is not a dependency.

# GPUI and NanoUI research for Zircon

Researched 2026-11-05 against primary source at the commits below. Zircon is the proposed name for a fresh native Zig desktop editor. The project directory was empty when inspected. Local `zig version` returned `0.17.0`.

| Repository | Pinned main commit | Commit time, UTC | License relevant to this work |
| --- | --- | --- | --- |
| zed-industries/zed | [`c7bea343838f42b4c14151393e41f0bbe033c95e`][zed-commit] | 2026-11-04 19:25:28 | GPUI and inspected native platform crates: Apache-2.0. Zed editor, language, text: GPL-3.0-or-later. |
| justrach/nanoui | [`d1330a84fca9581cdcaff7fa71041b2cccf3066b`][nano-commit] | 2026-11-05 00:52:47 | Own code: MIT, copyright 2026 Rach Pradhan. Third-party notices retain separate terms. |

License evidence is in the crate manifests, NanoUI's license and third-party notices. NanoUI acknowledges GPUI design influence and includes its Apache license; this does not make Zed's editor code Apache-licensed. Learn from the editor's architecture and independently implement Zircon's editor unless adopting its GPL obligations is deliberate. [G-license] [G-editor-license] [G-language-license] [G-text-license] [N-license] [N-notices]

## Decisions

Use NanoUI's native `.view` content path for windows, application chrome, layout and rendering. Borrow GPUI's separation of document, editor state and viewport. Keep document edits and history in Zircon. Start on macOS with one UTF-8 document, one selection, fixed-height monospaced lines and no soft wrap. These are recommendations, not claims that an editor has been implemented or validated.

NanoUI's pinned manifest reports version `0.12.0` and requires Zig `0.17.0`, matching the installed compiler. Pin the full source commit when adding it. The README's installation example still names `v0.5.0`, so copying that command would select a different implementation. No dependency was installed during this research. [N-manifest] [N-readme]

## What GPUI actually does

### Entities and rendering

`App` owns entity state. `Entity<T>` is a typed, reference-counted handle; reading or updating the value needs an application context. `Context<T>` adds services tied to that entity. `notify` signals a change to observers; `emit` sends a typed event to subscribers. This is retained application state with explicit change notification. [G-ownership]

An entity whose type implements `Render` can appear as a view. Its `render(&mut self, window, context)` returns an element tree. Elements implement `Element`; small stateless components can implement `RenderOnce`. Stable element IDs associate interaction state across frames. The durable entity and the element tree are different objects. Avoid describing GPUI as either a completely retained widget tree or a completely stateless immediate-mode toolkit. [G-element]

Caching is explicit in this revision. `Entity::cached(style)` and `AnyView::cached(style)` can reuse a rendered subtree, including recorded prepaint/paint work. Notifications invalidate it, and the API requires definite sizing rather than measuring the cached subtree's children. Zircon does not need this cache machinery for its initial UI. [G-view]

### Layout, prepaint and paint

The `Element` contract has three stages, with state passed between them. [G-element]

1. `request_layout` registers layout requirements and returns a layout ID plus request state. GPUI uses Taffy for its layout tree.
2. `prepaint` receives resolved bounds, records hitboxes and prepares geometry needed for drawing and interaction.
3. `paint` consumes the earlier state and records drawing operations. It can also install input handlers and event listeners. Painting does not mean issuing an OS drawing call for each widget.

Zed's `EditorElement` shows why the split matters. Its prepaint stage derives font metrics, gutter bounds, scrolling and visible text layouts from an editor snapshot. Paint registers editor actions, key listeners and the text-input handler, then draws backgrounds, selections, text, cursors and overlays. The text area is a custom element, with substantial preparation outside the final paint traversal. [G-editor-element]

### Actions, focus and text input

Actions are named, typed commands, optionally with data. Key bindings map keystrokes or multi-key sequences to actions under context predicates such as `Editor`. The focus path determines applicable contexts. Nested handlers can use capture and bubble phases; more local bindings take precedence over enclosing pane/workspace bindings. Command definition, shortcut selection and command handling are separate. [G-action] [G-dispatch] [G-window]

Typing also has a separate protocol. `EntityInputHandler` exposes surrounding text, selection, marked composition, replacement operations and character geometry. Platform-facing ranges use UTF-16 in this interface. `EditorElement::paint` installs the handler through `Window::handle_input`. Shortcut processing alone cannot implement dead keys, IME composition or native candidate positioning. [G-input] [G-editor-element]

### Text storage, editor behavior and displayed text

Zed separates several responsibilities:

- `text::Buffer` implements underlying text operations and history. Its snapshot contains ropes, fragment/version information and undo state. This is a collaboration-capable text engine, far beyond a string widget. [G-text]
- `language::Buffer` wraps that text engine with language, parsing, diagnostics and file-related state. [G-language]
- `MultiBuffer` presents one or more buffers/excerpts as one editing view. An ordinary single-buffer editor is its singleton case. [G-multi]
- `Editor` owns focus, selections, scroll management and an entity for the display map, while referencing its `MultiBuffer`. [G-editor]
- `DisplayMap` transforms buffer positions through inlays, folds, tabs, wrapping and blocks. `EditorElement` handles actual geometry and drawing. A buffer byte offset and a displayed row/column are therefore different coordinates. [G-display] [G-editor-element]

GPUI's own text system shapes and lays out text for rendering. It does not supply Zed's document transactions, selection semantics or file editing behavior. Zircon should copy the responsibility boundaries, while omitting multi-buffers, collaboration and the full display-map stack initially. [G-text-system] [G-editor]

### GPU and platform boundaries

GPUI records a `Scene` containing quads, shadows, paths, underlines, glyph sprites and surfaces, with ordering and clipping. Platform windows consume the scene. Text shaping/rasterization and glyph-atlas caching support drawing; GPU rendering does not move document editing onto the GPU. [G-scene] [G-text-system]

At this pin, native platform code is split into crates. `gpui_platform` chooses the OS implementation. Apple rendering lives in `gpui_apple::metal_renderer`; Linux windows use `gpui_wgpu::WgpuRenderer`, with Vulkan and GL enabled in native context selection; Windows has a Direct3D 11 renderer. Do not base a new port on an older account of Linux using Blade. These are the inspected paths, not a runtime guarantee for every machine. [G-platform] [G-metal] [G-linux] [G-wgpu] [G-directx]

## How NanoUI differs

NanoUI's native UI is custom-drawn Zig UI inside native windows. The optional web-page path is separate. `ui.View` holds an opaque pointer to caller-owned state and a build function. Zircon must keep that state alive for the window; NanoUI does not provide GPUI's application entity graph. [N-ui] [N-readme]

A native frame builds nodes, measures and arranges them with NanoUI's own layout code, and paints GPU instances. Interactions use previously laid-out rectangles. If building changes state, the frame can rebuild before drawing, clearing consumed input edges. There is no public GPUI-style per-element `request_layout`/`prepaint`/`paint` trait. Keep builds repeatable and perform file I/O through explicit commands, so a rebuild cannot repeat a save or reload. [N-frame] [N-context] [N-layout]

Immediate-mode does not mean state disappears. `Context` retains keyed focus, editing, scrolling and animation state. `ui.key` and `ui.keyInt` give the next box stable identity. Use document IDs for tabs and editor regions rather than their current array positions. Widget strings must outlive the build function until painting; use document-owned memory or the frame allocator, never a returning stack buffer. [N-context] [N-widgets] [N-ui]

NanoUI's `Context.shortcut` matches and consumes a shortcut. `Shortcut.native` maps Command to Control off Apple platforms. Text fields expose system, Emacs and Vim keymaps, but these are widget editing behaviors rather than GPUI's context/action dispatch tree. Zircon needs its own small command enum and focus-based routing. [N-shortcuts] [N-input] [N-keymap]

The renderer consumes a common stream of clipped, instanced shapes and atlas glyphs. macOS uses Metal; Linux has OpenGL 3.3 with CPU fallback; Windows has D3D11 and fallback paths. Glass and compositing can split rendering into additional passes, so the README's single-draw description is not a universal frame invariant. Reuse this renderer instead of building a Zig GPUI renderer. [N-gpu] [N-metal] [N-linux] [N-windows]

Text uses CoreText on Apple platforms by default. The portable path maps decoded code points to TrueType glyphs with fallback and pair kerning. The inspected loop does not perform full complex-script shaping or bidirectional layout. Windows DirectWrite support here is for rasterization and related glyph rendering information; it does not replace that shaping loop. Cross-platform text parity requires further work. [N-text] [N-text-tt] [N-dwrite]

## Editor-specific limits and implementation recommendations

1. Build the first editable spike with `ui.TextBuffer` and `ui.textArea`, setting `.submit_on_return = false`. The default submits on Return. Treat this as a wiring check: `AreaOptions` lacks monospaced text styling and horizontal scrolling, and its implementation builds wrapped lines across the whole buffer before emitting visible text. It is a composer widget, not an editor viewport. [N-field] [N-area]

2. Own a `Document` containing path, UTF-8 bytes, line-start offsets, a revision and edit history. A contiguous allocation is adequate for deliberately small files; defer a piece table or rope until measured edit costs justify it. Own an `EditorState` separately, with document ID, anchor/caret, preferred horizontal position and scroll offsets. This leaves room for two views of one document later.

3. Replace the built-in history before claiming normal file editing. NanoUI's history has **12 snapshot slots, each limited to 1,024 bytes**. A larger snapshot clears history. Its `TextBuffer` is a contiguous `ArrayList(u8)` using the C allocator. Implement document edit transactions with removed/inserted bytes and selection before/after, plus typing groups and a memory budget. Never let a toolkit text field maintain a second independent history for the same document. [N-undo] [N-field]

4. Implement one focusable editor region and render only visible fixed-height lines plus overscan. NanoUI's `ui.list` demonstrates that geometry, but a row list alone does not provide cross-line editing, selection, caret scrolling or IME. Use monospaced rich text for visible lines and rectangles for selections, gutter and caret. Expand tabs according to tab stops in the display mapping, preserving literal tabs in the document. [N-list] [N-types]

5. Adapt native text input into document transactions. NanoUI already converts AppKit text services into `TextOp.insert`, `set_marked`, `unmark` and editing commands, and publishes focused text/caret geometry back to the platform. A custom viewport must preserve both directions of that protocol. Some integration uses low-level context fields, so prove this adapter before committing to the viewport design. Keep UTF-8 byte offsets, UTF-16 platform ranges, grapheme boundaries and screen positions distinct. NanoUI's field movement helpers advance UTF-8 code points, which alone is insufficient for combined characters and emoji sequences. [N-input] [N-textinput] [N-area] [N-field]

6. Route menus and shortcuts into one Zircon command handler: open, save, undo, redo, find, select all and movement. Give the focused search field or editor first chance to consume editing shortcuts, then handle application commands. Consume each input once across rebuilds. Add syntax-colored spans after basic editing works; defer LSP, trees, multi-cursors and soft wrapping.

7. Make saving explicit and failure-aware. Preserve detected line endings and the last saved revision, report read/write errors, and replace files through a temporary file in the same directory. Protect unsaved edits on close. These are Zircon responsibilities; native UI rendering provides none of them.

Before expanding scope, verify undo/redo on a file larger than 1 KiB, tabs, CRLF round trips, combining characters, emoji, CJK input, selection across lines, scrolling while composing, and focus changes into/out of search. Test edit transactions without a window and use `ui.Tester` for UI behavior. Its synthetic input does not exercise OS IME candidate windows. NanoUI's Windows IME investigation explicitly records real-window failures that offscreen checks missed. [N-tester] [N-ime-note]

## Evidence limits

This was source inspection, not a build, launch, benchmark or complete platform audit. Compiler availability and manifest compatibility do not prove NanoUI builds with every SDK. No claims about Zed/NanoUI relative speed, idle CPU, maximum file size or production readiness were measured. The commit pins make these findings reproducible; upstream `main` and the low-level NanoUI editor integration may change. Zircon's name was not checked for availability.

## Pinned source references

[zed-commit]: https://github.com/zed-industries/zed/commit/c7bea343838f42b4c14151393e41f0bbe033c95e
[nano-commit]: https://github.com/justrach/nanoui/commit/d1330a84fca9581cdcaff7fa71041b2cccf3066b
[G-license]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/Cargo.toml
[G-editor-license]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/editor/Cargo.toml
[G-language-license]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/language/Cargo.toml
[G-text-license]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/text/Cargo.toml
[G-ownership]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/_ownership_and_data_flow.rs
[G-element]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/element.rs#L46-L180
[G-view]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/view.rs
[G-editor-element]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/editor/src/element.rs#L8479-L10280
[G-action]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/action.rs
[G-dispatch]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/key_dispatch.rs#L1-L55
[G-window]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/window.rs#L6293-L6700
[G-input]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/input.rs#L7-L145
[G-text]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/text/src/text.rs#L59-L145
[G-language]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/language/src/buffer.rs#L104-L220
[G-multi]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/multi_buffer/src/multi_buffer.rs#L71-L100
[G-editor]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/editor/src/editor.rs#L975-L1010
[G-display]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/editor/src/display_map.rs#L1-L35
[G-text-system]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/text_system.rs
[G-scene]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui/src/scene.rs
[G-platform]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui_platform/src/gpui_platform.rs
[G-metal]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui_apple/src/metal_renderer.rs
[G-linux]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui_linux/src/linux/wayland/window.rs
[G-wgpu]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui_wgpu/src/wgpu_context.rs#L470-L505
[G-directx]: https://github.com/zed-industries/zed/blob/c7bea343838f42b4c14151393e41f0bbe033c95e/crates/gpui_windows/src/directx_renderer.rs
[N-license]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/LICENSE
[N-notices]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/THIRD_PARTY_NOTICES.md
[N-manifest]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/build.zig.zon
[N-readme]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/README.md
[N-ui]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/ui.zig
[N-frame]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/frame.zig
[N-context]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/context.zig#L296-L355
[N-layout]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/layout.zig
[N-widgets]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/widgets.zig#L13-L21
[N-shortcuts]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/context_hooks.zig#L243-L252
[N-input]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/input.zig
[N-keymap]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/keymap.zig
[N-gpu]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/gpu.zig
[N-metal]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/metal.zig
[N-linux]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/linux/surface.zig
[N-windows]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/windows/surface_gpu.zig
[N-text]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/text.zig#L1-L30
[N-text-tt]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/text_tt.zig#L219-L263
[N-dwrite]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/dwrite.zig
[N-field]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/textfield.zig
[N-area]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/textarea.zig
[N-undo]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/undo.zig#L1-L99
[N-list]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/list.zig
[N-types]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/types.zig#L276-L323
[N-textinput]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/textinput.zig
[N-tester]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/src/ui/tester.zig
[N-ime-note]: https://github.com/justrach/nanoui/blob/d1330a84fca9581cdcaff7fa71041b2cccf3066b/docs/windows-ime.md
