# Compact UI composition

Use `b.fluent()` for application and reusable-control composition. Factories create frame-owned nodes immediately; chains add typed styles, children, entity views and handlers. Finish the root or a dynamic-list item with `.build()`.

For application changes, start with the [UI ownership map](../apps/zircon/src/views/README.md).
Each feature owns its input definitions and rendering. Shell input initialization
only assembles feature-owned entity handles; placeholders and feature styling
belong beside the control's layout.

The application, settings, popovers, terminal chrome, text-input control and examples use this API. Low-level constructors remain inside the framework, custom-element ownership boundaries and API-contract tests.

This render function comes from the [compiled headless counter](../examples/counter/main.zig).

<!-- example: examples/counter/main.zig#render -->
```zig
pub fn render(self: *const Counter, builder: *ui.Ui) !ui.Element {
    const f = builder.fluent();
    return f.column().gap_px(12).p(6)
        .child(f.textFmt("Count: {d}", .{self.count}))
        .child(f.button(.{ .label = "Increment" }).id(.named("increment")).on_click(builder.onClick(increment)))
        .build();
}
```

The [native counter](../examples/counter_native/main.zig) uses the fluent API below. `./tools/zig build examples-check` compiles both examples on macOS and the headless example on other targets. `check` includes this step and checks that the embedded sources match their compiled files.

## GPUI-style element chains

`b.fluent()` creates a frame-scoped factory. It supports chained styling, children, keys and typed events over the same elements and `Style` as the eager constructors. Finish the root with `.build()`. Copies of a chain alias one draft, so a helper must not treat them as independent immutable variants. After build, decoration through that chain returns `BuilderFinished` and fails the staging frame. Repeating build itself returns the same element.

<!-- example: examples/counter_native/main.zig#render -->
```zig
pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
    const animated_width = try b.animate(1, 30 + @as(f32, @floatFromInt(self.count % 8)) * 35, .{ .spring = .{} });
    const f = b.fluent();
    return f.div().flex_col().p(7).gap_px(18).bg(.rgb(0x171b24))
        .child(f.text("Zircon UI").text_size(26))
        .child(f.textFmt("Count: {d}", .{self.count}))
        .child(f.button(.{ .label = "Increment" }).id(.named("increment"))
            .h_px(42).p_3().rounded_px(7).bg(.rgb(0x395bd8))
            .on_click(b.onClick(increment)))
        .child(f.div().w_px(animated_width).h_px(5).rounded_px(2).bg(.rgb(0x72b8f2)))
        .build();
}
```

`child` accepts a chain, `Element` or `!Element`. `children` accepts mixed tuples, arrays, slices and pointers to arrays. Adding a chain child builds it immediately. The parent copies child handles, then validates and attaches all its direct children during build. A duplicate, already-parented child or self-child fails the frame. Raw constructors accept a fluent result through `.build()`.

Strings, button labels, keys and callback payloads still copy eagerly into the frame. Successful custom construction still transfers ownership immediately. Keep owning custom creation explicit, for example `const custom = try b.custom(T, value, style); return f.adopt(custom).w_full().build();`. `adopt` decorates an existing element but cannot append children to it. Failed custom construction leaves ownership with the caller.

Fluent methods carry failures to build and also record the first error in the staging frame. Ignoring a failed chain cannot commit a different fallback root. A stale chain fails with `InvalidFrame` before reading its draft, and cannot poison a newer frame at the same address. Factories and chains belong to the current render scope and cannot outlive their frame/application.

Styles validate when the element builds. Last field update wins, so `.gap_px(-1).gap_2()` has a valid final gap. `.style(value)` replaces the complete `Style`. `.when(condition, .{ .background = color })` changes only named fields; unknown names fail compilation even for a false condition. Nested whole values require a typed `TextStyle` or `Insets`; dedicated text and padding methods preserve contextual inference.

| Methods | Meaning |
| --- | --- |
| `flex`, `flex_col`, `items_center`, `justify_center`, `justify_between` | Supported layout direction/alignment. `flex` selects row direction. Containers otherwise default to column. |
| `w`, `h` | Existing typed `Length`, including pixels, percent, rem and viewport units. |
| `w_px`, `h_px`, `min_w_px`, `min_h_px`, `w_full`, `h_full` | Exact logical pixels or 100 percent of available size. |
| `p(units)`, `p_2`, `p_3`, `p_4`, `gap_2` | Four logical pixels per spacing unit. `p_4` is 16 pixels. This scale does not follow a custom layout rem value. |
| `padding`, `p_px`, `px_px`, `gap_px` | Typed insets, all-edge pixels, horizontal pixels and exact pixel gap. Later padding calls replace the affected edges. |
| `grow`, `shrink_0`, `scroll_y_px`, `overflow_hidden` | Existing flex/scroll/clip behavior. These do not add CSS wrapping or grid. |
| `bg`, `hover_bg`, `rounded_px`, `opacity`, `cursor` | Typed paint/input style fields. Palette values come from the caller. |
| `text_size`, `text_color` | Text style fields, using logical pixel size and typed color. |
| `id`, `on_click`, `on_input` | Stable copied keys and existing typed handlers. Click binding requires a button. Button options retain tooltip, focus and capture support. |

All editor views use this API. Application theme and feature state stay above the framework; the chain has no `Shell`, extension or product-palette dependency.

## Entity views, focus and capture

`f.view(entity)` renders a child entity through its normal const borrow and records its frame dependency. Decorate it with `.id(key)`, `.focusable()`, `.autofocus()` and `.request_focus(generation)`. A generation change requests focus after the frame commits. Autofocus takes effect when a logical control first enters the tree.

`.on_capture(handler)` adds capture handling while preserving the child view's input handler. `.listeners(.{ .on_input = ..., .on_capture = ..., .focusable = ... })` updates only specified values. A failed handler resolves before changes are installed. `.modal()` traps focus and pointer routing in its subtree; `.drag_region()` marks native draggable content.

`f.row()`, `f.column()` and `f.stack()` create the corresponding containers. `.items(alignment)`, `.justify(alignment)`, `.direction(direction)`, `.grow_by(factor)` and `.shrink_by(factor)` cover values beyond the common shortcuts. `.min_w`, `.max_w`, `.min_h` and `.max_h` accept typed lengths. `.margin` and `.text_style` accept typed insets and text styles. `.background` and `.hover_background` accept optional colors. `.refine(.{ ... })` updates named style fields; `.style(value)` replaces the full style.

## Source conventions and migration

Imports belong in the file's module declarations. Module comments describe ownership and responsibilities; public contracts explain lifetimes, failure behavior and units where callers need them.

`python3 tools/migrate_fluent.py apps/zircon/src packages/zircon_ui/src/controls packages/zircon_editor/src examples` migrates composition calls while preserving literals and comments. `python3 tools/hoist_zig_imports.py <source directories>` hoists nested literal imports and reuses module aliases. Both accept `--check`, and `zig build check` runs those checks against application/framework/tool sources, tests and examples. Migration tests cover nested syntax, comment terminators, alias collisions and repeatability.

## Children and errors

`column`, `row`, `stack` and `div` accept heterogeneous tuples of `Element` and `!Element`. Arrays, slices and pointers to arrays or tuples also work. A dynamic list can keep using `std.ArrayList(Element)` with explicit allocation handling. Child order follows tuple/array/slice order.

Constructors execute when the tuple expression is evaluated. Text and callback payloads are copied immediately. Containers resolve child errors and validate frame identity and parenting before changing parent links. A child error leaves the previously committed frame, callbacks, IME target and deadlines intact.

Successful custom construction immediately registers cleanup with the frame. If a parent later fails, frame rollback releases that custom value. A failed `custom` call leaves ownership with its caller. Use the existing explicit cleanup convention around owning custom inputs; a tuple does not transfer resources that `custom` failed to accept.

`styled`, `key`, `listen`, `autofocus`, `requestFocus`, `modal` and `dragRegion` accept an element or a fallible element result. For example, `b.styled(b.text("Heading"), style)` propagates either construction error through the modifier.

## Keys, listeners and styles

Buttons accept `key`, `on_input`, `on_capture`, `focusable` and `autofocus` beside their existing label, click handler, style, tooltip and composed children. Their handler fields accept plain handlers, fallible handlers or absence. `listen` also accepts fallible input/capture handlers.

Use `.key = .named("save")` for a string key. Numeric keys retain `.key = .{ .number = id }`. Keys remain frame-owned copies and retain existing focus reconciliation and duplicate-key validation.

Styles remain typed `Style` values with the existing validation. Context inference permits `.padding = .all(12)` and `.background = .rgb(0x171b24)`. `Length.pixels` permits `.width = .pixels(120)` alongside the existing union forms for pixels, percentages, rem units and viewport units. These factories preserve validation, including rejection of invalid lengths or colors.

## Typed callback payloads

Use `b.onClickWith(callback, payload)` and `b.onInputWith(callback, payload)`. The callback's fourth parameter supplies the payload type. For a callback ending in `action: Command`, write `.on_click = b.onClickWith(Self.onCommand, .save)` without a cast or inner `try`.

Callbacks retain their entity token and a frame-owned copy of the payload. Pointer/slice payloads and structs containing borrowed pointers fail compilation, including pointers wrapped inside error unions. Entity read/update results use the same recursive copied-value check. A normal click callback has `(*Self, *Event(Click), *Context(Self))`; a payload click callback adds the concrete payload as its fourth parameter. Input callbacks use `Event(Input)`.

The old value-first signature was removed. Existing projects can use `python3 tools/migrate_ui_callbacks.py --from <old-revision>` to migrate calls present in a fixed source revision. Repeating the migration against that same revision leaves migrated calls intact. The repository's migration used `c4ce46e`; `--check` verifies that no known old call remains. This tool does not change unrelated edits or invent calls missing from that revision.

## Verification

Run `./tools/zig build check`. It compiles the examples, validates the embedded source, checks invalid child and borrowed payload compile failures, and runs composition/ownership/input tests. `./tools/zig build test-native-fresh` checks actual native input and editor integration. Syntax changes do not establish new editor features or other desktop platform support.
