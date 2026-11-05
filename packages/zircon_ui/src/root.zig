//! Verified framework foundations. This module has no native or GPU imports.
pub const App = @import("app/app.zig").App;
pub const Context = @import("app/app.zig").Context;
pub const Entity = @import("entity/entity.zig").Entity;
pub const Scope = @import("entity/scope.zig").Scope;
pub const testing = struct {
    pub const Harness = @import("testing/headless.zig").Harness;
};
pub const Ui = @import("ui/ui.zig").Ui;
pub const Element = @import("ui/element.zig").Element;
pub const ElementKey = @import("ui/element.zig").Key;
pub const Style = @import("ui/style.zig").Style;
pub const Length = @import("ui/style.zig").Length;
pub const Insets = @import("layout/geometry.zig").Insets;
pub const Event = @import("event/event.zig").Event;
pub const Click = @import("event/event.zig").Click;
pub const DispatchControl = @import("event/event.zig").DispatchControl;
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
