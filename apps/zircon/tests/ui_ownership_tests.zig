const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;

const Ops = struct {
    fn prepare(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const fields = self.fields.?;
        const Set = struct {
            fn call(value: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), bytes: []const u8) !void {
                value.bytes.clearRetainingCapacity();
                try value.bytes.appendSlice(value.allocator, bytes);
                value.cursor = bytes.len;
                value.anchor = bytes.len;
                value.revision +%= 1;
                context.notify();
            }
        };
        try cx.update(fields.workspace.path, Set.call, .{"/tmp/open-draft"});
        try cx.update(fields.workspace.query, Set.call, .{"Command draft"});
        try cx.update(fields.project.destination, Set.call, .{"/tmp/clone-draft"});
        try cx.update(fields.git_commit.message, Set.call, .{"Commit draft"});
    }

    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&click, cx, which);
    }

    fn retained(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const fields = self.fields.?;
        const Check = struct {
            fn call(value: *const ui.controls.TextInput, expected: []const u8) !void {
                try t.expectEqualStrings(expected, value.bytes.items);
            }
        };
        try cx.read(fields.workspace.path, Check.call, .{"/tmp/open-draft"});
        try cx.read(fields.workspace.query, Check.call, .{"Command draft"});
        try cx.read(fields.project.destination, Check.call, .{"/tmp/clone-draft"});
        try cx.read(fields.git_commit.message, Check.call, .{"Commit draft"});
    }

    fn style(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), theme: []const u8) !void {
        try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = theme }});
        try self.onSettings(cx, self.settings.?);
        const Check = struct {
            fn call(value: *const ui.controls.TextInput) !void {
                try t.expectEqual(@as(f32, 0), value.appearance.border.a);
                try t.expect(!value.show_focus_border);
                try t.expectEqualStrings("Commit message…", value.placeholder);
            }
        };
        try cx.read(self.fields.?.git_commit.message, Check.call, .{});
        const Picker = struct {
            fn call(value: *const ui.controls.TextInput) !void {
                try t.expectEqual(@as(f32, 0), value.appearance.border.a);
                try t.expectEqual(@as(f32, 0), value.appearance.background.a);
                try t.expect(!value.show_focus_border);
            }
        };
        try cx.read(self.fields.?.workspace.query, Picker.call, .{});
    }
};

test "Git and project dialogs preserve drafts owned by other inputs across theme changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, null));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.command, .{.palette});
    try app.update(owner, Ops.prepare, .{});
    try app.update(owner, Ops.command, .{.git_branches});
    try app.update(owner, Ops.retained, .{});
    try app.update(owner, Ops.command, .{.open_project});
    try app.update(owner, Ops.retained, .{});
    try app.update(owner, Ops.command, .{.recent_projects});
    try app.update(owner, Ops.retained, .{});
    try app.update(owner, Ops.command, .{.new_file});
    try app.update(owner, Ops.command, .{.language_picker});
    try app.update(owner, Ops.retained, .{});
    try app.update(owner, Ops.style, .{"zircon.light"});
    try app.update(owner, Ops.style, .{"zircon.dark"});
    try app.update(owner, Ops.retained, .{});
    _ = try app.step(0);
}
