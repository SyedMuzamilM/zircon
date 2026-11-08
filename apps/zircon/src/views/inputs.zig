//! The shell owns entity lifetimes; each feature defines and styles its inputs.
const std = @import("std");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const buffer_search = @import("buffer_find.zig");
const v = @import("components.zig");
const extensions = @import("extensions.zig");
const git_commit = @import("git/commit.zig");
const git_picker = @import("git/picker.zig");
const input = @import("input.zig");
const project = @import("open_project.zig");
const workspace = @import("overlays.zig");
const language_picker = @import("popovers/language_picker.zig");
const recent_projects = @import("popovers/recent_projects.zig");
const project_search = @import("project_search.zig");
const Shell = shell.Shell;

pub const Fields = struct {
    buffer_search: buffer_search.Fields,
    project_search: project_search.Fields,
    extensions: extensions.Fields,
    project: project.Fields,
    workspace: workspace.Fields,
    language_picker: language_picker.Fields,
    recent_projects: recent_projects.Fields,
    git_commit: git_commit.Fields,
    git_picker: git_picker.Fields,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        const fields: Fields = .{
            .buffer_search = try buffer_search.Fields.init(cx, a),
            .project_search = try project_search.Fields.init(cx, a),
            .extensions = try extensions.Fields.init(cx, a),
            .project = try project.Fields.init(cx, a),
            .workspace = try workspace.Fields.init(cx, a),
            .language_picker = try language_picker.Fields.init(cx, a),
            .recent_projects = try recent_projects.Fields.init(cx, a),
            .git_commit = try git_commit.Fields.init(cx, a),
            .git_picker = try git_picker.Fields.init(cx, a),
        };
        _ = try cx.observe(fields.buffer_search.query, Shell.onFindQuery);
        _ = try cx.observe(fields.buffer_search.replacement, Shell.onFindQuery);
        _ = try cx.observe(fields.git_picker.query, Shell.onGitPickerQuery);
        return fields;
    }

    pub fn style(self: Fields, cx: *ui.Context(Shell), colors: v.Palette) !void {
        const appearance = v.inputAppearance(colors);
        inline for (.{ "buffer_search", "project_search", "extensions", "project", "workspace", "language_picker", "recent_projects", "git_picker" }) |feature| {
            const fields = @field(self, feature);
            inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
                try input.appearance(cx, @field(fields, field), appearance, false);
            }
        }
        try self.git_commit.style(cx, colors);
    }
};
