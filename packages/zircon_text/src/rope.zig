//! Immutable AVL rope. Functions borrow their inputs and return one owned root
//! reference. Reference counts are changed only by the document's owner thread.
//! Leaves contain valid UTF-8, at most 4 KiB. Summary metrics index bytes, LF and
//! UTF-16 without rebuilding an index after each edit.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const leaf_capacity = 4096;
pub const Summary = struct { bytes: usize = 0, lines: usize = 0, utf16: usize = 0, bare_cr: usize = 0, starts_lf: bool = false, ends_cr: bool = false };
pub const Node = struct {
    references: usize = 1,
    height: u16,
    summary: Summary,
    data: union(enum) { leaf: []u8, branch: struct { left: *Node, right: *Node } },
};
pub fn summary(root: ?*const Node) Summary {
    return if (root) |node| node.summary else .{};
}
fn height(root: ?*const Node) u16 {
    return if (root) |node| node.height else 0;
}
pub fn retain(root: ?*Node) ?*Node {
    if (root) |node| {
        std.debug.assert(node.references != std.math.maxInt(usize));
        node.references += 1;
    }
    return root;
}
pub fn release(a: Allocator, root: ?*Node) void {
    const node = root orelse return;
    std.debug.assert(node.references > 0);
    node.references -= 1;
    if (node.references != 0) return;
    switch (node.data) {
        .leaf => |bytes| a.free(bytes),
        .branch => |b| {
            release(a, b.left);
            release(a, b.right);
        },
    }
    a.destroy(node);
}
fn scan(bytes: []const u8) Summary {
    var result: Summary = .{ .bytes = bytes.len, .starts_lf = bytes.len > 0 and bytes[0] == '\n', .ends_cr = bytes.len > 0 and bytes[bytes.len - 1] == '\r' };
    for (bytes, 0..) |byte, index| {
        if (byte == '\r' and (index + 1 == bytes.len or bytes[index + 1] != '\n')) result.bare_cr += 1;
        if (byte == '\n') result.lines += 1;
        if (byte & 0xc0 != 0x80) result.utf16 += if (byte >= 0xf0) @as(usize, 2) else 1;
    }
    return result;
}
fn add(a: Summary, b: Summary) !Summary {
    if (a.bytes == 0) return b;
    if (b.bytes == 0) return a;
    return .{ .bare_cr = a.bare_cr + b.bare_cr - @intFromBool(a.ends_cr and b.starts_lf), .starts_lf = a.starts_lf, .ends_cr = b.ends_cr, .bytes = std.math.add(usize, a.bytes, b.bytes) catch return error.DocumentTooLarge, .lines = std.math.add(usize, a.lines, b.lines) catch return error.DocumentTooLarge, .utf16 = std.math.add(usize, a.utf16, b.utf16) catch return error.DocumentTooLarge };
}
fn leaf(a: Allocator, bytes: []const u8) !?*Node {
    if (bytes.len == 0) return null;
    std.debug.assert(bytes.len <= leaf_capacity);
    const node = try a.create(Node);
    errdefer a.destroy(node);
    node.* = .{ .height = 1, .summary = scan(bytes), .data = .{ .leaf = try a.dupe(u8, bytes) } };
    return node;
}
fn branch(a: Allocator, left: *Node, right: *Node) !*Node {
    const sums = try add(left.summary, right.summary);
    const node = try a.create(Node);
    node.* = .{ .height = 1 + @max(left.height, right.height), .summary = sums, .data = .{ .branch = .{ .left = retain(left).?, .right = retain(right).? } } };
    return node;
}
/// Balances a join whose child heights differ by at most two.
fn balance(a: Allocator, left: *Node, right: *Node) !*Node {
    if (left.height > right.height + 1) {
        const l = left.data.branch;
        if (l.left.height >= l.right.height) {
            const next_right = try branch(a, l.right, right);
            defer release(a, next_right);
            return branch(a, l.left, next_right);
        }
        const pivot = l.right.data.branch;
        const next_left = try branch(a, l.left, pivot.left);
        defer release(a, next_left);
        const next_right = try branch(a, pivot.right, right);
        defer release(a, next_right);
        return branch(a, next_left, next_right);
    }
    if (right.height > left.height + 1) {
        const r = right.data.branch;
        if (r.right.height >= r.left.height) {
            const next_left = try branch(a, left, r.left);
            defer release(a, next_left);
            return branch(a, next_left, r.right);
        }
        const pivot = r.left.data.branch;
        const next_left = try branch(a, left, pivot.left);
        defer release(a, next_left);
        const next_right = try branch(a, pivot.right, r.right);
        defer release(a, next_right);
        return branch(a, next_left, next_right);
    }
    return branch(a, left, right);
}
fn joinRaw(a: Allocator, left: ?*Node, right: ?*Node) anyerror!?*Node {
    const l = left orelse return retain(right);
    const r = right orelse return retain(left);
    if (l.height > r.height + 1) {
        const next = try joinRaw(a, l.data.branch.right, r);
        defer release(a, next);
        return balance(a, l.data.branch.left, next.?);
    }
    if (r.height > l.height + 1) {
        const next = try joinRaw(a, l, r.data.branch.left);
        defer release(a, next);
        return balance(a, next.?, r.data.branch.right);
    }
    return branch(a, l, r);
}
const Pop = struct { rest: ?*Node, edge: *Node };
fn popLast(a: Allocator, node: *Node) anyerror!Pop {
    if (node.data == .leaf) return .{ .rest = null, .edge = retain(node).? };
    const popped = try popLast(a, node.data.branch.right);
    errdefer release(a, popped.edge);
    defer release(a, popped.rest);
    return .{ .rest = try joinRaw(a, node.data.branch.left, popped.rest), .edge = popped.edge };
}
fn popFirst(a: Allocator, node: *Node) anyerror!Pop {
    if (node.data == .leaf) return .{ .rest = null, .edge = retain(node).? };
    const popped = try popFirst(a, node.data.branch.left);
    errdefer release(a, popped.edge);
    defer release(a, popped.rest);
    return .{ .rest = try joinRaw(a, popped.rest, node.data.branch.right), .edge = popped.edge };
}
fn edge(root: *Node, first: bool) *Node {
    var node = root;
    while (node.data == .branch) node = if (first) node.data.branch.left else node.data.branch.right;
    return node;
}
/// Merges adjacent small boundary leaves before height-based joining. This
/// prevents repeated tiny insertions from retaining one leaf per character.
pub fn join(a: Allocator, left: ?*Node, right: ?*Node) !?*Node {
    const l = left orelse return retain(right);
    const r = right orelse return retain(left);
    const last = edge(l, false);
    const first = edge(r, true);
    if (last.summary.bytes + first.summary.bytes > leaf_capacity) return joinRaw(a, l, r);
    const lp = try popLast(a, l);
    defer {
        release(a, lp.rest);
        release(a, lp.edge);
    }
    const rp = try popFirst(a, r);
    defer {
        release(a, rp.rest);
        release(a, rp.edge);
    }
    var buffer: [leaf_capacity]u8 = undefined;
    const x = lp.edge.data.leaf;
    const y = rp.edge.data.leaf;
    @memcpy(buffer[0..x.len], x);
    @memcpy(buffer[x.len..][0..y.len], y);
    const merged = try leaf(a, buffer[0 .. x.len + y.len]);
    defer release(a, merged);
    const prefix = try joinRaw(a, lp.rest, merged);
    defer release(a, prefix);
    return joinRaw(a, prefix, rp.rest);
}
pub fn fromBytes(a: Allocator, bytes: []const u8) anyerror!?*Node {
    if (bytes.len <= leaf_capacity) return leaf(a, bytes);
    var middle = bytes.len / 2;
    while (bytes[middle] & 0xc0 == 0x80) middle -= 1;
    const left = try fromBytes(a, bytes[0..middle]);
    defer release(a, left);
    const right = try fromBytes(a, bytes[middle..]);
    defer release(a, right);
    return joinRaw(a, left, right);
}
pub const Split = struct { left: ?*Node, right: ?*Node };
pub fn split(a: Allocator, root: ?*Node, offset: usize) anyerror!Split {
    const node = root orelse {
        std.debug.assert(offset == 0);
        return .{ .left = null, .right = null };
    };
    std.debug.assert(offset <= node.summary.bytes);
    if (offset == 0) return .{ .left = null, .right = retain(node) };
    if (offset == node.summary.bytes) return .{ .left = retain(node), .right = null };
    switch (node.data) {
        .leaf => |bytes| {
            const left = try leaf(a, bytes[0..offset]);
            errdefer release(a, left);
            return .{ .left = left, .right = try leaf(a, bytes[offset..]) };
        },
        .branch => |b| {
            if (offset == b.left.summary.bytes) return .{ .left = retain(b.left), .right = retain(b.right) };
            if (offset < b.left.summary.bytes) {
                const pieces = try split(a, b.left, offset);
                errdefer release(a, pieces.left);
                defer release(a, pieces.right);
                return .{ .left = pieces.left, .right = try joinRaw(a, pieces.right, b.right) };
            }
            const pieces = try split(a, b.right, offset - b.left.summary.bytes);
            errdefer release(a, pieces.right);
            defer release(a, pieces.left);
            return .{ .left = try joinRaw(a, b.left, pieces.left), .right = pieces.right };
        },
    }
}
pub fn replace(a: Allocator, root: ?*Node, start: usize, end: usize, text: []const u8) !?*Node {
    const suffix = try split(a, root, end);
    defer {
        release(a, suffix.left);
        release(a, suffix.right);
    }
    const prefix = try split(a, suffix.left, start);
    defer {
        release(a, prefix.left);
        release(a, prefix.right);
    }
    const inserted = try fromBytes(a, text);
    defer release(a, inserted);
    const beginning = try join(a, prefix.left, inserted);
    defer release(a, beginning);
    return join(a, beginning, suffix.right);
}
pub fn leafAt(root: *const Node, offset: usize) struct { bytes: []const u8, start: usize } {
    std.debug.assert(offset < root.summary.bytes);
    var node = root;
    var at = offset;
    while (node.data == .branch) {
        const b = node.data.branch;
        if (at < b.left.summary.bytes) node = b.left else {
            at -= b.left.summary.bytes;
            node = b.right;
        }
    }
    return .{ .bytes = node.data.leaf, .start = offset - at };
}
pub fn byteAt(root: *const Node, offset: usize) u8 {
    const found = leafAt(root, offset);
    return found.bytes[offset - found.start];
}
pub fn isBoundary(root: ?*const Node, offset: usize) bool {
    const length = summary(root).bytes;
    return offset <= length and (offset == length or byteAt(root.?, offset) & 0xc0 != 0x80);
}
pub fn prefixMetrics(root: ?*const Node, offset: usize) Summary {
    const node = root orelse {
        std.debug.assert(offset == 0);
        return .{};
    };
    std.debug.assert(offset <= node.summary.bytes);
    if (offset == node.summary.bytes) return node.summary;
    return switch (node.data) {
        .leaf => |bytes| scan(bytes[0..offset]),
        .branch => |b| if (offset <= b.left.summary.bytes) prefixMetrics(b.left, offset) else add(b.left.summary, prefixMetrics(b.right, offset - b.left.summary.bytes)) catch unreachable,
    };
}
pub fn newline(root: *const Node, ordinal: usize) usize {
    std.debug.assert(ordinal < root.summary.lines);
    var node = root;
    var nth = ordinal;
    var base: usize = 0;
    while (node.data == .branch) {
        const b = node.data.branch;
        if (nth < b.left.summary.lines) node = b.left else {
            nth -= b.left.summary.lines;
            base += b.left.summary.bytes;
            node = b.right;
        }
    }
    for (node.data.leaf, 0..) |byte, i| if (byte == '\n') {
        if (nth == 0) return base + i;
        nth -= 1;
    };
    unreachable;
}
pub fn offsetFromUtf16(root: ?*const Node, units: usize) !usize {
    if (units > summary(root).utf16) return error.InvalidOffset;
    var node = root orelse return 0;
    var remaining = units;
    var base: usize = 0;
    while (node.data == .branch) {
        const b = node.data.branch;
        if (remaining <= b.left.summary.utf16) node = b.left else {
            remaining -= b.left.summary.utf16;
            base += b.left.summary.bytes;
            node = b.right;
        }
    }
    var i: usize = 0;
    while (i < node.data.leaf.len and remaining > 0) {
        const first = node.data.leaf[i];
        const width: usize = if (first >= 0xf0) 2 else 1;
        if (remaining < width) return error.InvalidUtf16Boundary;
        remaining -= width;
        i += std.unicode.utf8ByteSequenceLength(first) catch unreachable;
    }
    return base + i;
}
/// A borrowed streaming leaf iterator. Its source snapshot must remain alive.
pub const Iterator = struct {
    const Item = struct { node: *const Node, base: usize };
    stack: [128]Item = undefined,
    count: usize = 0,
    start: usize,
    end: usize,
    pub fn init(root: ?*const Node, start: usize, end: usize) Iterator {
        var result: Iterator = .{ .start = start, .end = end };
        if (root) |node| {
            result.stack[0] = .{ .node = node, .base = 0 };
            result.count = 1;
        }
        return result;
    }
    pub fn next(iterator: *Iterator) ?[]const u8 {
        while (iterator.count > 0) {
            iterator.count -= 1;
            const item = iterator.stack[iterator.count];
            if (item.base >= iterator.end or item.base + item.node.summary.bytes <= iterator.start) continue;
            switch (item.node.data) {
                .leaf => |bytes| return bytes[iterator.start -| item.base..@min(bytes.len, iterator.end - item.base)],
                .branch => |b| {
                    std.debug.assert(iterator.count + 2 <= iterator.stack.len);
                    iterator.stack[iterator.count] = .{ .node = b.right, .base = item.base + b.left.summary.bytes };
                    iterator.stack[iterator.count + 1] = .{ .node = b.left, .base = item.base };
                    iterator.count += 2;
                },
            }
        }
        return null;
    }
};
pub const Stats = struct { nodes: usize = 0, leaves: usize = 0, height: usize = 0, bytes: usize = 0 };
/// Recomputes all summaries and balancing invariants. Used by storage tests.
pub fn validate(root: ?*const Node) !Stats {
    const node = root orelse return .{};
    if (node.references == 0) return error.InvalidReferences;
    switch (node.data) {
        .leaf => |bytes| {
            if (bytes.len == 0 or bytes.len > leaf_capacity or !std.unicode.utf8ValidateSlice(bytes) or !std.meta.eql(scan(bytes), node.summary) or node.height != 1) return error.InvalidLeaf;
            return .{ .nodes = 1, .leaves = 1, .height = 1, .bytes = bytes.len };
        },
        .branch => |b| {
            const l = try validate(b.left);
            const r = try validate(b.right);
            if (@max(l.height, r.height) - @min(l.height, r.height) > 1 or node.height != 1 + @max(l.height, r.height) or !std.meta.eql(try add(b.left.summary, b.right.summary), node.summary)) return error.InvalidBalance;
            return .{ .nodes = 1 + l.nodes + r.nodes, .leaves = l.leaves + r.leaves, .height = node.height, .bytes = l.bytes + r.bytes };
        },
    }
}
