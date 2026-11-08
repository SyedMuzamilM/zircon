"""Lexical safety and repeatability for the fluent/import migrations."""
import unittest
from migrate_fluent import migrate
from hoist_zig_imports import hoist
from fluent_layout import migrate as layout


class MigrationTests(unittest.TestCase):
    def test_button_layout_preserves_optional_handlers_and_literals(self):
        source = '''// .button(.{ .children = "ignore" })
const value = b.fluent().button(.{ .label = "Run", .style = .{ .height = .{ .px = 30 } }, .children = &.{item}, .on_click = if (busy) null else try b.onClick(run) }).build();
'''
        result = layout(source)
        self.assertIn('// .button(.{ .children = "ignore" })', result)
        self.assertIn('.on_click = if (busy) null else try b.onClick(run)', result)
        self.assertIn('.children(&.{item})', result)
        self.assertIn('.h(', result)
        self.assertEqual(result, layout(result))

    def test_fluent_nested_calls_skip_comments_and_strings(self):
        source = '''// b.text("leave this alone")
const literal = "b.row(.{}, .{})";
const node = try b.row(.{ .gap = 8 }, .{ b.text("value, )"), b.button(.{ .label = "Run" }) });
'''
        result = migrate(source)
        self.assertIn('// b.text("leave this alone")', result)
        self.assertIn('"b.row(.{}, .{})"', result)
        self.assertIn('.gap_px(', result)
        self.assertIn('.flex()', result)
        self.assertIn('.button(', result)
        self.assertEqual(result, migrate(result))

    def test_arguments_keep_line_comment_boundaries(self):
        source = 'return b.div(.{}, .{ b.text("item") // child comment\n});\n'
        result = migrate(source)
        self.assertIn('// child comment\n', result)
        self.assertEqual(result, migrate(result))

    def test_imports_reuse_aliases_avoid_shadowing_and_preserve_literals(self):
        source = '''//! Module docs.
const std = @import("std");
const literal = "@import(\\\"not-code\\\")";
fn run() void {
    const parser = 1;
    _ = @import("parser.zig").read;
    _ = @import("std").mem;
    _ = parser;
}
'''
        result = hoist(source)
        self.assertTrue(result.startswith('//! Module docs.\nconst std = @import("std");'))
        self.assertIn('const parser_module = @import("parser.zig");', result)
        self.assertIn('_ = parser_module.read;', result)
        self.assertIn('_ = std.mem;', result)
        self.assertIn('"@import(\\\"not-code\\\")"', result)
        self.assertEqual(result, hoist(result))


if __name__ == '__main__':
    unittest.main()
