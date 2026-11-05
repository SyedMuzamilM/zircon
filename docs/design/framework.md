> Historical design exploration. Superseded by the [user-supplied specification](../specification/framework-api-v0.1.md).

# Zircon UI architecture

## Problem

Zircon needs an independently implemented native UI package and an editor that
consumes it. NanoUI and GPUI are research references, with no source copied into
this implementation. AppKit, CoreText, and Metal are operating-system facilities.
The editor's document and filesystem modules remain separate from the framework.

## Usage

Applications own their state and give `Application` a `View`. A view receives a
`Context`, partitions its bounds with `Layout`, builds controls with stable ids,
and draws custom content through clipped rectangle and text operations. A
standalone counter exercises the same public package as the editor.

```zig
const ui = @import("zircon_ui");
fn view(counter: *Counter, c: *ui.Context) !void {
    var column = ui.Layout.column(c.bounds().inset(24), 12);
    try c.label(column.take(32), "A separate framework", .{});
    if (try c.button(ui.id("increment"), column.take(36), "Increment", .{})) {
        counter.count += 1;
        c.invalidate();
    }
}
```

## Shape and synthesis decision

Candidate A is the base. Rectangular partition layout gives the first frame exact
bounds, avoids a retained widget arena, and keeps application state the only
source of truth. Candidate B's pointer capture, leased GPU buffers, bounded text
caches, and explicit native input snapshot are accepted into that design. Both
designs were independently produced on the inherited model. Model diversity was
reduced; no different-family cross-judge was configured, so that step was skipped.

| Criterion | A | B |
| --- | --- | --- |
| Independent toolkit and standalone consumer | Meets | Meets |
| Small public interface for this editor | Direct frame and layout interface | More node/setter/invalidation concepts |
| Native text input ownership | Document-owned text snapshot | Document-owned text snapshot |
| Predictable memory | Transient scene, bounded caches | Persistent arena plus bounded caches |
| Extension cost for custom code editor | Custom draw operations | Custom node protocol |

The interface hides native objects, GPU buffers, font objects, glyph atlases, C
transport, hit testing, and redraw scheduling. It exposes geometry deliberately,
because a code editor needs control over viewport and selection layout. It does
not claim to implement CSS flexbox, GPUI's entity graph, or a general accessibility
tree. The retained alternative is a viable later direction if a second complex
application proves that intrinsic measurement is necessary.

## Ownership and outcome contracts

- `Application` owns a context, window, renderer, and native event loop. State
  referenced by its view must outlive it. Initialize in place so C callbacks
  cannot point at a moved Zig value.
- `Context` owns transient scene storage, focus, pointer capture, and the last
  completed hit index. It consumes each input event once. Rebuilds see no event.
- `Layout` only partitions rectangles. Scene clipping also clips hit testing.
- The private system adapter owns AppKit objects, CoreText layouts and a bounded
  glyph atlas. It copies instances before returning to Zig and leases GPU buffers
  until their command buffers complete. UTF-16 is translated at the native seam.
- The editor owns documents, history, tabs, selection, syntax, and scroll offsets.
  Rendering submits visible rows. Filesystem changes never happen in the renderer.
- Failed scene construction reports an error. It never submits partially built
  scene pointers. Dirty documents require an explicit close decision.

## Tradeoffs accepted

macOS is the first system adapter. System shaping avoids bundling a font engine.
Explicit layout keeps the initial package small but requires applications to
choose dimensions. One window is supported initially. Left-to-right code editing
and a single selection precede grapheme-aware and bidirectional editing.

## Implementation reconciliation

The parent accepted the candidate-A base and candidate-B grafts on 2026-11-05,
following the user's correction. `platform/bridge.h` is the private backend
contract. The editor will migrate completely; the old NanoUI interface will be
deleted. Measurements must distinguish framework caches, whole-process footprint,
CPU scene building, GPU rendering, and actual user editing operations.

## Next implementation step

Build the system adapter and the Zig context against the private contract, run
the standalone counter, then migrate the editor and verify its complete save path.
