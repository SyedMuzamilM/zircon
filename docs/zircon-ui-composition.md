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

The [native counter](../examples/counter_native/main.zig) uses the same API with styling and animation. `./tools/zig build examples-check` compiles both examples on macOS and the headless example on other targets. `check` includes this step and checks that the embedded source above matches its compiled file.

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
