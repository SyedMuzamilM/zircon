const std = @import("std");
const term = @import("zircon_terminal");
test "SGR 256-color, truecolor, attributes and reset" {
    var t = try term.Terminal.init(std.testing.allocator, 40, 10, 100);
    defer t.deinit(std.testing.allocator);
    try t.feed(std.testing.allocator, "\x1b[1;38;2;10;20;30;48;5;200mA\x1b[0mB");
    const row = t.activeScreen().viewRow(0);
    try std.testing.expectEqual(@as(u21, 'A'), row.cells[0].code);
    try std.testing.expect(row.cells[0].style.bold);
    try std.testing.expectEqual(term.Color{ .rgb = 0x0a141e }, row.cells[0].fg);
    try std.testing.expectEqual(term.Color{ .indexed = 200 }, row.cells[0].bg);
    try std.testing.expectEqual(@as(u21, 'B'), row.cells[1].code);
    try std.testing.expect(!row.cells[1].style.bold);
    try std.testing.expectEqual(term.Color.default, row.cells[1].fg);
}

test "alternate screen preserves primary buffer and cursor" {
    var t = try term.Terminal.init(std.testing.allocator, 20, 5, 100);
    defer t.deinit(std.testing.allocator);
    try t.feed(std.testing.allocator, "hello\r\nworld");
    try std.testing.expectEqual(@as(usize, 1), t.row);
    try std.testing.expectEqual(@as(usize, 5), t.col);

    try t.feed(std.testing.allocator, "\x1b[?1049hALT");
    try std.testing.expect(t.in_alt_screen);
    try std.testing.expectEqual(@as(u21, 'A'), t.activeScreen().viewRow(0).cells[0].code);

    try t.feed(std.testing.allocator, "\x1b[?1049l");
    try std.testing.expect(!t.in_alt_screen);
    try std.testing.expectEqual(@as(usize, 1), t.row);
    try std.testing.expectEqual(@as(usize, 5), t.col);
    try std.testing.expectEqual(@as(u21, 'h'), t.activeScreen().viewRow(0).cells[0].code);
}

test "wrapped lines rejoin cleanly on smart copy and trim trailing spaces" {
    var t = try term.Terminal.init(std.testing.allocator, 5, 4, 100);
    defer t.deinit(std.testing.allocator);
    try t.feed(std.testing.allocator, "abcdefgh\r\nij");
    const s = t.activeScreenConst();
    try std.testing.expect(s.rowConst(0).wrapped);
    try std.testing.expect(!s.rowConst(1).wrapped);

    var sel: term.Selection = .{};
    sel.selectAll(s);
    const copied = try term.selection.extractText(std.testing.allocator, s, sel);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("abcdefgh\nij\n", copied);
}

test "OSC 2 title, OSC 7 cwd and OSC 52 clipboard" {
    var t = try term.Terminal.init(std.testing.allocator, 40, 5, 100);
    defer t.deinit(std.testing.allocator);
    try t.feed(std.testing.allocator, "\x1b]2;zig build\x07");
    try std.testing.expectEqualStrings("zig build", t.title);
    try t.feed(std.testing.allocator, "\x1b]7;file://mac/Users/syed/my%20repo\x07");
    try std.testing.expectEqualStrings("/Users/syed/my repo", t.cwd);
    try t.feed(std.testing.allocator, "\x1b]52;c;aGVsbG8=\x07");
    const clip = t.takeClipboard().?;
    defer std.testing.allocator.free(clip);
    try std.testing.expectEqualStrings("hello", clip);
}

test "lock-free SPSC ByteRing wrap-around" {
    var ring: term.pty.ByteRing = .{};
    const msg = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (0..20_000) |_| {
        const res = ring.push(msg);
        try std.testing.expectEqual(msg.len, res.written);
        const got = ring.pop(&out);
        try std.testing.expectEqualStrings(msg, got);
    }
}

const testing = std.testing;
var pty_wakes: std.atomic.Value(usize) = .init(0);

fn wakePtyTest() void {
    _ = pty_wakes.fetchAdd(1, .monotonic);
}

test "PTY wakes for real output and drains bursts larger than the ring" {
    if (comptime !term.pty.supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    pty_wakes.store(0, .monotonic);
    try tmp.dir.symLink(testing.io, "/bin/sh", "zircon-test-shell", .{});
    const path = try std.fmt.allocPrint(testing.allocator, "{s}:/usr/bin:/bin", .{root});
    defer testing.allocator.free(path);
    const process = try term.Pty.spawn(testing.allocator, root, 74, 19, .{ .command = "zircon-test-shell", .extra_env = &.{ .{ "PATH", "/missing" }, .{ "PATH", path }, .{ "ZIRCON_PTY_TEST", "yes" } }, .args = &.{
        "-c",
        \\test -t 0 && test "$TERM" = xterm-256color && test "$ZIRCON_PTY_TEST" = yes || exit 1
        \\stty -echo
        \\printf 'READY\n'
        \\IFS= read -r value
        \\printf 'INPUT=%s\n' "$value"
        \\stty size
        \\i=0
        \\while [ "$i" -lt 4096 ]; do
        \\  printf '%080d\n' "$i"
        \\  i=$((i+1))
        \\done
        \\printf 'DONE\n'
    } }, wakePtyTest);
    defer process.destroy();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);
    const deadline = std.Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (pty_wakes.load(.monotonic) == 0) {
        if (std.Io.Clock.awake.now(testing.io).compare(.gte, deadline)) return error.TerminalWakeTimeout;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    var sent = false;
    while (true) {
        var buf: [4096]u8 = undefined;
        try output.appendSlice(testing.allocator, process.drain(&buf));
        process.acknowledge();
        if (!sent and std.mem.indexOf(u8, output.items, "READY\r\n") != null) {
            process.resize(93, 27);
            try process.send("hello\n");
            sent = true;
        }
        if (process.isExited() and !process.hasData()) break;
        if (std.Io.Clock.awake.now(testing.io).compare(.gte, deadline)) return error.TerminalOutputTimeout;
        if (!process.hasData()) try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    try testing.expect(sent);
    try testing.expect(output.items.len > term.pty.ByteRing.capacity);
    try testing.expect(std.mem.indexOf(u8, output.items, "INPUT=hello\r\n27 93\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, output.items, "DONE\r\n"));
}

test "shrinking the dock keeps the primary prompt and cursor visible" {
    var terminal = try term.Terminal.init(testing.allocator, 80, 24, 100);
    defer terminal.deinit(testing.allocator);
    try terminal.feed(testing.allocator, "prompt$ ");
    try terminal.resize(testing.allocator, 40, 7);
    try testing.expectEqual(@as(usize, 0), terminal.row);
    try testing.expectEqual(@as(usize, 8), terminal.col);
    const screen = terminal.activeScreen();
    try testing.expectEqual(@as(u21, 'p'), screen.viewRow(0).cells[0].code);
    try testing.expectEqual(@as(usize, 7), screen.len);
}

test "scrollback eviction and clear preserve increasing line identities" {
    var terminal = try term.Terminal.init(testing.allocator, 5, 2, 3);
    defer terminal.deinit(testing.allocator);
    try terminal.feed(testing.allocator, "a\r\nb\r\nc\r\nd");
    const screen = terminal.activeScreenConst();
    try testing.expectEqual(@as(?usize, null), screen.logicalForAbsLine(0));
    try testing.expectEqual(@as(u21, 'b'), screen.rowConst(0).cells[0].code);
    const old_last = screen.absLineForLogical(screen.len - 1);
    terminal.clear();
    try testing.expect(screen.absLineForLogical(0) > old_last);
}

fn resizeWithAllocator(allocator: std.mem.Allocator) !void {
    var terminal = try term.Terminal.init(allocator, 5, 3, 12);
    defer terminal.deinit(allocator);
    try terminal.feed(allocator, "a\r\nb\r\nc\r\nd\r\ne");
    try terminal.resize(allocator, 16, 7);
    try terminal.feed(allocator, "test\r\ntest");
}

test "grid initialization and resize release memory on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, resizeWithAllocator, .{});
}

test "smart copy keeps the initial word in a backward drag and omits a wide wrap gap" {
    var terminal = try term.Terminal.init(testing.allocator, 12, 2, 100);
    defer terminal.deinit(testing.allocator);
    try terminal.feed(testing.allocator, "one two 例");
    const screen = terminal.activeScreenConst();
    var selected: term.Selection = .{};
    selected.startAt(screen, screen.absLineForLogical(0), 5, .word);
    selected.extendTo(screen, screen.absLineForLogical(0), 0);
    const words = try term.selection.extractText(testing.allocator, screen, selected);
    defer testing.allocator.free(words);
    try testing.expectEqualStrings("one two", words);

    try terminal.resize(testing.allocator, 3, 2);
    terminal.clear();
    try terminal.feed(testing.allocator, "ab界");
    selected.startAt(screen, screen.absLineForLogical(0), 0, .line);
    const wrapped = try term.selection.extractText(testing.allocator, screen, selected);
    defer testing.allocator.free(wrapped);
    try testing.expectEqualStrings("ab界", wrapped);
    try terminal.feed(testing.allocator, "\x1b[2;2H\x1b[X");
    try testing.expect(!screen.rowConst(1).cells[0].style.wide_lead);
    try testing.expect(!screen.rowConst(1).cells[1].style.wide_trail);
}

test "VT handles split escape sequences and DEC line graphics" {
    var terminal = try term.Terminal.init(testing.allocator, 16, 4, 100);
    defer terminal.deinit(testing.allocator);
    try terminal.feed(testing.allocator, "\x1b(0lqk\x1b(B\x1bPignored");
    try terminal.feed(testing.allocator, "\x1b\\\x1b[38:2::10:20:30mX\x1b[2;4r\x1b[?6h\x1b[1;2HY");
    const screen = terminal.activeScreenConst();
    const first = screen.rowConst(0).cells;
    try testing.expectEqual(@as(u21, '┌'), first[0].code);
    try testing.expectEqual(@as(u21, '─'), first[1].code);
    try testing.expectEqual(@as(u21, '┐'), first[2].code);
    try testing.expectEqual(@as(u21, 'X'), first[3].code);
    try testing.expectEqual(term.Color{ .rgb = 0x0a141e }, first[3].fg);
    try testing.expectEqual(@as(u21, 'Y'), screen.rowConst(1).cells[1].code);
    try terminal.feed(testing.allocator, "\x1b[18446744073709551615C");
    try testing.expectEqual(@as(usize, 15), terminal.col);
}

test "link detector parses URLs and file:line:col across wrapped rows" {
    var t = try term.Terminal.init(std.testing.allocator, 14, 6, 100);
    defer t.deinit(std.testing.allocator);
    try t.feed(std.testing.allocator, "err apps/zircon/src/shell.zig:42:10 fail");
    const s = t.activeScreenConst();
    var link = (try term.links.detectAt(std.testing.allocator, s, 0, 8)).?;
    defer link.deinit(std.testing.allocator);
    try std.testing.expectEqual(term.links.Kind.file, link.kind);
    try std.testing.expectEqualStrings("apps/zircon/src/shell.zig", link.target);
    try std.testing.expectEqual(@as(?usize, 42), link.line);
    try std.testing.expectEqual(@as(?usize, 10), link.column);
}

test "scrollback search finds wrapped matches and steps circularly" {
    var t = try term.Terminal.init(std.testing.allocator, 6, 4, 100);
    defer t.deinit(std.testing.allocator);
    try t.feed(std.testing.allocator, "hello_world\r\nWORLD");
    var results: term.search.Results = .{};
    defer results.deinit(std.testing.allocator);
    try term.search.findAll(std.testing.allocator, t.activeScreenConst(), "world", false, &results);
    try std.testing.expectEqual(@as(usize, 2), results.count());
    try std.testing.expectEqual(@as(usize, 1), results.active);
    _ = results.step(true);
    try std.testing.expectEqual(@as(usize, 0), results.active);
}

test "links detect Python tracebacks and decode local file URLs" {
    var terminal = try term.Terminal.init(testing.allocator, 18, 8, 100);
    defer terminal.deinit(testing.allocator);
    const allocator = testing.allocator;
    try terminal.feed(allocator, "  File \"src/path with space.py\", line 42, in run");
    const screen = terminal.activeScreenConst();
    var trace = (try term.links.detectAt(allocator, screen, screen.absLineForLogical(1), 2)).?;
    defer trace.deinit(allocator);
    try testing.expectEqualStrings("src/path with space.py", trace.target);
    try testing.expectEqual(@as(?usize, 42), trace.line);
    terminal.clear();
    try terminal.feed(allocator, "file://localhost/tmp/path%20space.zig:4");
    var file = (try term.links.detectAt(allocator, screen, screen.absLineForLogical(0), 3)).?;
    defer file.deinit(allocator);
    try testing.expectEqualStrings("/tmp/path space.zig", file.target);
    try testing.expectEqual(@as(?usize, 4), file.line);
}

test "terminal search includes both columns of wide text across a wrap" {
    var terminal = try term.Terminal.init(testing.allocator, 3, 3, 32);
    defer terminal.deinit(testing.allocator);
    try terminal.feed(testing.allocator, "ab界X");
    var results: term.search.Results = .{};
    defer results.deinit(testing.allocator);
    try term.search.findAll(testing.allocator, terminal.activeScreenConst(), "b界", true, &results);
    try testing.expectEqual(1, results.count());
    try testing.expectEqual(2, results.spans.items.len);
    try testing.expectEqual(2, results.spans.items[1].end_col);
}

test "terminal detects wrapped HTTP URLs with accurate click coordinates" {
    var terminal = try term.Terminal.init(testing.allocator, 14, 6, 100);
    defer terminal.deinit(testing.allocator);
    try terminal.feed(testing.allocator, "see https://example.test/a?b=1.");
    const screen = terminal.activeScreenConst();
    var link = (try term.links.detectAt(testing.allocator, screen, screen.absLineForLogical(1), 2)).?;
    defer link.deinit(testing.allocator);
    try testing.expectEqual(.url, link.kind);
    try testing.expectEqualStrings("https://example.test/a?b=1", link.target);
    try testing.expect(link.lineRange(screen.absLineForLogical(0), screen.cols) != null);
    try testing.expect(link.lineRange(screen.absLineForLogical(1), screen.cols) != null);
}
