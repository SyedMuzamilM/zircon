//! Search and reopen locally remembered workspaces.
const std = @import("std");
const ui = @import("zircon_ui");
const projects = @import("../../projects.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const field_input = @import("../input.zig");
const overlays = @import("../overlays.zig");
const panel = @import("panel.zig");
const Shell = shell.Shell;

pub const Fields = struct {
    query: field_input.Handle,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{ .query = try field_input.create(cx, a, query_options) };
    }
};

const query_options: field_input.Options = .{
    .placeholder = "Search projects…",
    .height = 38,
    .font_size = 14,
    .borderless = true,
};

pub fn prepare(self: *Shell, cx: *ui.Context(Shell)) !void {
    try field_input.reset(cx, self.fields.?.recent_projects.query, "", query_options);
}

fn choose(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    if (index >= self.recent.entries.items.len) return;
    _ = projects.open(self, cx, self.recent.entries.items[index], .local_folder) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    self.popup = .none;
    cx.notify();
}

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const query = try field_input.text(b, self.fields.?.recent_projects.query);
    var rows: std.ArrayList(ui.Element) = .empty;
    try panel.query(self, b, &rows, self.fields.?.recent_projects.query);
    var options: std.ArrayList(ui.Element) = .empty;
    for (self.recent.entries.items, 0..) |entry, i| if (overlays.matches(query, entry)) {
        try options.append(b.allocator(), try b.fluent().button(.{
            .label = entry,
        })
            .flex()
            .h(.{ .px = 46 })
            .shrink_0()
            .items_center()
            .gap_px(8)
            .padding(.{ .left = 10 })
            .background(if (options.items.len == self.overlay_index) c.selected else null)
            .hover_background(c.hover)
            .on_click(b.onClickWith(choose, @as(u32, @intCast(i))))
            .children(&.{
                try v.icon(b, .folder, c.muted, 14),
                try b.fluent().div().gap_px(3).min_w(.{ .px = 0 }).overflow_hidden().flex_col().children(.{
                    v.text(b, std.fs.path.basename(entry), c.text, 13),
                    v.text(b, entry, c.muted, 11),
                }).build(),
            }).build());
    };
    if (options.items.len == 0) try options.append(b.allocator(), try v.text(b, "No matches", c.muted, 13));
    const visible = try panel.options(self, b, &rows, options.items, 46);
    try rows.append(b.allocator(), try v.rule(b, c));
    try rows.append(b.allocator(), try v.menuRow(b, c, .open_project, "Open local folder or Git repository…", "", false));
    return panel.render(self, b, .{ .width = 380, .height = 84 + visible }, rows.items);
}

pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    const key = e.data.key_down.key;
    if (key != .up and key != .down and key != .enter) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const query = try field_input.read(cx, self.fields.?.recent_projects.query, arena.allocator());
    var indices: std.ArrayList(u32) = .empty;
    for (self.recent.entries.items, 0..) |entry, i| if (overlays.matches(query, entry)) try indices.append(arena.allocator(), @intCast(i));
    if (indices.items.len > 0) {
        self.overlay_index = @min(self.overlay_index, indices.items.len - 1);
        if (key == .down) self.overlay_index = (self.overlay_index + 1) % indices.items.len;
        if (key == .up) self.overlay_index = (self.overlay_index + indices.items.len - 1) % indices.items.len;
        if (key == .enter) {
            var click: ui.Event(ui.Click) = .{ .data = .{} };
            try choose(self, &click, cx, indices.items[self.overlay_index]);
        }
    }
    return true;
}
