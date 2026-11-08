# Compact UI composition

Use ordinary eager builders with tuples of elements or element results. The container propagates child errors, so static composition needs one outer fallible return. This render function comes from the [compiled headless counter](../examples/counter/main.zig).

<!-- example: examples/counter/main.zig#render -->
```zig
pub fn render(self: *const Counter, builder: *ui.Ui) !ui.Element {
    return builder.column(.{ .gap = 12, .padding = .all(24) }, .{
        builder.textFmt("Count: {d}", .{self.count}),
        builder.button(.{ .key = .named("increment"), .label = "Increment", .on_click = builder.onClick(increment) }),
    });
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

The editor's common menu rows and dynamic project list use this API. Application theme and feature state stay above the framework; the chain has no `Shell`, extension or product-palette dependency.

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
