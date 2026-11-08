# Fluent API grounding

`Ui` borrows a staging `Frame` and identifies the entity rendering through a const `App.read` borrow. Constructors copy strings, keys, child handles and callback payloads into that frame immediately. `Element` contains an index and frame epoch. It owns nothing.

The frame owns nodes, handler payloads and custom cleanup hooks. Containers normalize every child, validate frame identity, duplicates and existing parents, allocate indices and append the parent before changing child-parent links. Successful custom construction reserves both registries before taking ownership, then immediately registers cleanup. An earlier sibling error can coexist with later successfully constructed siblings; frame discard releases them all.

The window validates layout, painting, focus reconciliation, animation and native submission before swapping CPU frames. Errors retain the committed handlers, focus, dependencies and text-input target. Typed handlers contain generational entity identity and copied pointer-free payloads, never a mutable render borrow.

The fluent API must preserve these rules. A copied chain cannot become valid because its frame address now belongs to a later epoch. Errors must reach render. Repeated child methods must preserve atomic parenting and custom cleanup. Text and keys must not acquire a deferred borrowing lifetime. Dynamic arrays and slices must remain supported without large stack buffers.

There is one existing `Style`, validated at the render boundary. `Ui.styled` replaces a complete style. `row`, `column` and `stack` force direction. Layout defaults one rem to 16 logical pixels. Fluent precedence, spacing scale, exact pixel values, conditional styles and theme values must be explicit. This design adds the requested GPUI-style version without creating a second ownership model or an unrelated style representation.

Compare the native counter, menu rows in `apps/zircon/src/views/components.zig`, and dynamic project rows in `apps/zircon/src/views/project.zig`. These cover eager text formatting, animation, copied command payloads, stable keys, input listeners, hover/selected styles and dynamic child lists. The reference is Zed's actual editor/GPUI code at `b5cd310b3b54dfc659fcc06453e6358843dfe216`.

Grounding came from a read-only source explainer on the inherited session model. No other-family judge is configured. Runtime ownership remains unchanged, so a new ownership-history investigation is not required.
