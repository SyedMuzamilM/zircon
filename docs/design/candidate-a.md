> Historical design exploration. Superseded by the [user-supplied specification](../specification/framework-api-v0.1.md).

# Candidate A: event-driven immediate frames

## Problem

Zircon needs its own reusable native UI package. The current NanoUI-backed shell does not meet that requirement. Retain the independent document and workspace modules, but replace their UI consumer. Build for macOS and Metal first. Use Apple system APIs for windowing and font shaping, with no dependency on NanoUI, GPUI, or another widget toolkit.

## Usage, written before the interface

The smallest app is a window and a function of caller-owned state:

```zig
const ui = @import("zircon_ui");

const Counter = struct {
    count: u32 = 0,
    fn view(self: *Counter, f: *ui.Frame) !void {
        var column = ui.Layout.column(f.bounds().inset(24), 12);
        try f.label(column.take(28), "A standalone Zircon UI app", .{});
        if (try f.button(.named("increment"), column.take(36), "Increment", .{})) {
            self.count += 1;
            f.invalidate();
        }
        try f.label(column.rest(), f.print("{d}", .{self.count}), .{});
    }
};

pub fn main(init: std.process.Init) !void {
    var counter: Counter = .{};
    try ui.run(init, .{ .title = "Counter", .width = 480, .height = 320 },
        .init(&counter, Counter.view));
}
```

A custom editor uses the same clipping, text geometry, input, and renderer:

```zig
fn editorView(editor: *Editor, f: *ui.Frame, bounds: ui.Rect) !void {
    const id: ui.Id = .named("editor");
    const interaction = f.interact(id, bounds, .{ .focusable = true });
    for (f.eventsFor(id)) |event| try editor.handle(event);
    var canvas = try f.canvas(bounds);
    defer canvas.end();
    for (editor.visibleLines(bounds.h)) |line| {
        try canvas.text(line.position, line.text, .{ .font = .mono, .size = 14 });
    }
    if (interaction.focused) f.textInput(id, editor.inputTarget(bounds));
}
```

A test injects domain input events and inspects the same scene:

```zig
var harness = try ui.Tester.init(allocator, .init(&counter, Counter.view), .{});
defer harness.deinit();
try harness.click(.named("increment"));
try std.testing.expectEqual(@as(u32, 1), counter.count);
try harness.snapshot("counter.png");
```

## Shape

The public module exports values the application understands: `Rect`, `Color`, `Id`, `Event`, `Layout`, `Frame`, `View`, `TextInputTarget`, `Tester`, and `run`. It exposes no Objective-C object, GPU handle, C transport struct, atlas slot, or window delegate.

```zig
pub const View = struct { state: *anyopaque, build: *const fn (*anyopaque, *Frame) anyerror!void };
pub fn run(init: std.process.Init, options: WindowOptions, view: View) !void;
pub const Frame = struct {
    pub fn bounds(self: *Frame) Rect;
    pub fn button(self: *Frame, id: Id, rect: Rect, text: []const u8, style: ButtonStyle) !bool;
    pub fn label(self: *Frame, rect: Rect, text: []const u8, style: TextStyle) !void;
    pub fn canvas(self: *Frame, rect: Rect) !Canvas;
    pub fn interact(self: *Frame, id: Id, rect: Rect, options: InteractionOptions) Interaction;
    pub fn eventsFor(self: *Frame, id: Id) []const Event;
    pub fn textInput(self: *Frame, id: Id, target: TextInputTarget) void;
    pub fn invalidate(self: *Frame) void;
};
```

`run` owns the native app, input queue, frame storage, and renderer until its window closes. The caller owns view state and all document bytes. A frame borrows state synchronously. Text command arguments are copied into retained frame storage before the view returns, so stack formatting cannot create dangling pointers. Scene construction either succeeds completely or retains the last valid scene and reports the error.

`Layout` is pure rectangular partitioning: inset, row, column, fixed track, and remaining track. This avoids a persistent element graph and a second layout pass. Frame methods attach stable IDs to interactive rectangles. The last completed frame owns the hit index; pointer events resolve through that index before the next build. Resizes force a new layout before accepting pointer presses against changed geometry.

`Canvas` records clipped rectangles, rounded rectangles, shaped text, selection fills, and caret strokes. Clip scopes intersect with their parents and affect drawing and hit tests. The framework owns its scene representation and converts ordered items into Metal instances. A custom editor needs no renderer internals.

Suggested package layout:

```text
packages/zircon_ui/build.zig
packages/zircon_ui/build.zig.zon
packages/zircon_ui/src/root.zig       public interface
packages/zircon_ui/src/frame.zig      scene, hit index, focus, frame storage
packages/zircon_ui/src/layout.zig     pure rectangular layout
packages/zircon_ui/src/text.zig       shaping cache and caret/index geometry
packages/zircon_ui/src/platform/macos.h   private C transport
packages/zircon_ui/src/platform/macos.m   AppKit, CoreText, Metal adapter
examples/counter.zig
src/ui/                              Zircon editor views
src/editor/                          text transactions, selection, syntax
src/workspace/                       paths, open documents, filesystem policy
```

The Objective-C adapter handles NSWindow, NSView, NSTextInputClient, native menus/dialogs, and a CAMetalLayer. It calls the framework through a private C ABI with explicit lifetimes and byte counts. It never reads an editor struct. Metal shaders belong to this package, and the renderer batches rectangles and glyphs into instances with explicit clip bounds.

## Text and input contract

CoreText shapes strings into glyph IDs and positions, including fallback fonts. The text module caches bounded shaped runs and maps byte offsets to caret positions. Glyph-cache keys include the actual font, glyph ID, size, and scale. A small R8 glyph atlas stores reusable coverage; separate color glyph storage is needed for color emoji. Atlas eviction never changes glyph UVs referenced by an in-flight frame. Synchronize at eviction or allocate a fresh atlas generation and retire the old one after GPU completion.

`TextInputTarget` supplies current UTF-8 surrounding text, selection, marked range, caret rectangle, and an edit callback. The adapter translates Cocoa's UTF-16 ranges at this seam. The editor remains the sole text owner. An IME update is a replace-marked event, not a synthetic keypress; commit and cancel are distinct. A composition session is one document transaction. The same event stream covers insertion, clipboard, selection, navigation, and semantic commands. Command dispatch consumes an event once, including across redraws.

Focus selects one target by stable ID. Key shortcuts resolve before text interpretation; an unhandled key goes to NSTextInputClient. Mouse drag capture remains with the pressed ID until release. Hover alone may redraw, but an idle application schedules no frames. Caret blink uses a timer only while focused, and respects reduced motion.

## Tradeoffs accepted

- Explicit rectangle layout gives predictable first-frame geometry and a small implementation. A general intrinsic-size flexbox solver can be added behind a different layout module after a second app proves the need.
- CoreText and AppKit are system dependencies. Their correct text input and font behavior are more useful than writing a font shaper or window server binding.
- A single native window is the first implementation. The public `View` and scene remain per-window so multiwindow support does not require shared mutable focus or atlas state.
- Bounded caches and visible-line rendering constrain UI memory, but the existing full-document undo snapshots remain an editor memory cost. Do not claim low document memory until edits use bounded deltas or a piece table.
- Shader compilation at startup is acceptable for development. Ship a compiled metallib for release to measure startup without runtime shader-compiler costs.

## Alternatives considered

A retained element/entity graph can offer automatic intrinsic sizing, change propagation, and subtree caching. It requires callers to learn node ownership, subscriptions, invalidation, and reconciliation before building a small app. This candidate puts event routing, scene generation, and native integration behind the frame while exposing only ordinary app state and rectangles.

A public raw C drawing interface makes the implementation smaller but pushes text geometry, clipping, input conversion, and focus into every application. Reject it because those are the complex behaviors a reusable UI framework should own.

## Verification and measurements

Run pure layout/intersection and event-consumption tests without a window. Run shaping, UTF-8/UTF-16 range conversion, selection geometry, IME composition, glyph eviction, and Metal offscreen snapshots against the native adapter. Exercise a standalone counter and the editor to prove the package has no editor dependency. Test file edit/save and cancellation through actual native application dispatch.

Record optimized stripped executable size, clean launch time, settled resident/private memory, frame CPU time, and GPU completion time on a named machine and OS. Use fixed scenes and warmed font caches, repeat runs, and retain raw samples. Distinguish cache limits from measured process memory and distinguish an idle counter from a fully configured Zed workspace. Any Zed comparison needs the same files, window size, visible lines, and disabled extra services; until that measurement exists, publish Zircon's numbers without a faster-than-Zed claim.

## Synthesis decision and reconciliation

Candidate A is submitted independently for the parent to compare with candidate B. Both seats inherit one model, so model diversity is reduced. The configured model sheet has no different-family judge; the parent must record that cross-judging was skipped. No implementation or performance result is claimed here.

The next implementation step is a standalone counter rendered by the framework's own native window, rectangle shader, and glyph atlas before migrating the editor.
