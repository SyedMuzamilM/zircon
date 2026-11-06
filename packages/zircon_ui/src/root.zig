//! Verified framework foundations. This module has no native or GPU imports.
pub const Subscription = @import("app/app.zig").Subscription;
pub const App = @import("app/app.zig").App;
pub const typography = @import("text/typography.zig");
pub const WindowHandle = @import("app/window.zig").Handle;
pub const WindowOptions = @import("app/window.zig").Options;
pub const Input = @import("event/event.zig").Input;
pub const Point = @import("layout/geometry.zig").Point;
pub const Key = @import("platform/interface.zig").Key;
pub const Modifiers = @import("platform/interface.zig").Modifiers;
pub const LayoutCx = @import("ui/custom.zig").LayoutCx;
pub const LayoutResult = @import("ui/custom.zig").LayoutResult;
pub const PrepaintCx = @import("ui/custom.zig").PrepaintCx;
pub const PaintCx = @import("ui/custom.zig").PaintCx;
pub const animation = @import("animation/timeline.zig");
pub const tasks = @import("app/tasks.zig");
pub const TextRange = @import("platform/interface.zig").TextRange;
pub const TextSnapshot = @import("platform/interface.zig").TextSnapshot;
pub const TextEdit = @import("platform/interface.zig").TextEdit;
pub const Keymap = @import("event/actions.zig").Keymap;
pub const Chord = @import("event/actions.zig").Chord;
pub const controls = struct {
    pub const metrics = @import("controls/metrics.zig");
    pub const icons = @import("controls/icons.zig");
    pub const TextInput = @import("controls/text_input.zig").TextInput;
    pub const Scroll = @import("controls/scroll.zig").Scroll;
    pub const visibleRows = @import("controls/scroll.zig").visibleRows;
};
pub const Context = @import("app/app.zig").Context;
pub const Entity = @import("entity/entity.zig").Entity;
pub const Scope = @import("entity/scope.zig").Scope;
pub const testing = struct {
    pub const Harness = @import("testing/headless.zig").Harness;
    pub const native = if (@import("zircon_options").native) struct {
        pub const objc = @import("platform/macos/objc.zig");
        pub const pump = @import("platform/macos/window.zig").pump;
        pub const now = @import("platform/macos/window.zig").now;
    } else void;
};
pub const Ui = @import("ui/ui.zig").Ui;
pub const Element = @import("ui/element.zig").Element;
pub const ElementKey = @import("ui/element.zig").Key;
pub const Style = @import("ui/style.zig").Style;
pub const Length = @import("ui/style.zig").Length;
pub const Insets = @import("layout/geometry.zig").Insets;
pub const Event = @import("event/event.zig").Event;
pub const Click = @import("event/event.zig").Click;
pub const Rect = @import("layout/geometry.zig").Rect;
pub const Size = @import("layout/geometry.zig").Size;
pub const layout = struct {
    pub const Style = @import("ui/style.zig").Style;
    pub const Length = @import("ui/style.zig").Length;
    pub const Insets = @import("layout/geometry.zig").Insets;
    pub const Constraints = @import("layout/flex.zig").Constraints;
    pub const LayoutResult = @import("layout/flex.zig").Layout;
    pub const calculate = @import("layout/flex.zig").calculate;
    pub const Measurer = @import("layout/measure.zig").Measurer;
    pub const FixedMetrics = @import("layout/measure.zig").FixedMetrics;
};
pub const Color = @import("layout/geometry.zig").Color;
pub const TextStyle = @import("text/style.zig").TextStyle;
pub const graphics = struct {
    pub const images = @import("graphics/images.zig");
    pub const Painter = @import("graphics/painter.zig").Painter;
    pub const Scene = @import("graphics/scene.zig").Frame;
    pub const paintTree = @import("graphics/tree_paint.zig").paint;
};
