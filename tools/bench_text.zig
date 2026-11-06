//! Warm CoreText layout lookup workload. Each result is consumed by CoreText;
//! this measures shaping-cache lookup plus metric access, not typing latency.
const std = @import("std");
const native = @import("native");
pub fn main(init: std.process.Init) !void {
    const pool = native.objc.Pool.init();
    defer pool.deinit();
    var system = native.text.TextSystem.init(init.gpa);
    defer system.deinit();
    system.setTypography(.{ .code_font = .menlo, .ui_font = .system });
    var lines: [256][]u8 = undefined;
    for (&lines, 0..) |*line, index| line.* = try std.fmt.allocPrint(init.arena.allocator(), "const entry_{d} = render(\"Zircon 日本\");", .{index});
    for (lines) |line| _ = try system.layout(line, 14, true);
    const start = native.window.now();
    var checksum: f64 = 0;
    for (0..250_000) |index| {
        const layout = try system.layout(lines[(index * 73) % lines.len], 14, true);
        checksum += native.text.CTLineGetTypographicBounds(layout.line, null, null, null);
    }
    const elapsed = native.window.now() - start;
    if (system.shape_hits != 250_000 or system.shape_misses != 256 or checksum <= 0) return error.IncompleteBenchmark;
    std.debug.print("layout_lookup_ms={d:.3} hits={d} misses={d} checksum={d:.0}\n", .{ elapsed * 1000, system.shape_hits, system.shape_misses, checksum });
}
