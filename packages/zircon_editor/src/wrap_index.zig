//! A persistent sequence of source lines measured in bytes and visual rows.
//! Leaves store line-relative segments so an edit can share the whole suffix.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const leaf_lines = 32;
pub const Segment = struct { start: usize, end: usize, x: f32 };
pub const Line = struct { bytes: usize, rows: usize };

const Measure = struct {
    lines: usize = 0,
    bytes: usize = 0,
    rows: usize = 0,

    fn add(left: Measure, right: Measure) Measure {
        return .{ .lines = left.lines + right.lines, .bytes = left.bytes + right.bytes, .rows = left.rows + right.rows };
    }

    fn line(value: Line) Measure {
        return .{ .lines = 1, .bytes = value.bytes, .rows = value.rows };
    }
};

pub const Node = struct {
    refs: usize = 1,
    height: u8,
    measure: Measure,
    data: union(enum) {
        leaf: struct { lines: []const Line, segments: []const Segment },
        branch: struct { left: *Node, right: *Node },
    },
};

pub fn measure(node: ?*const Node) Measure {
    return if (node) |root| root.measure else .{};
}

fn retain(node: ?*Node) ?*Node {
    if (node) |root| root.refs += 1;
    return node;
}

pub fn release(a: Allocator, node: ?*Node) void {
    const root = node orelse return;
    root.refs -= 1;
    if (root.refs != 0) return;
    switch (root.data) {
        .leaf => |data| {
            a.free(data.lines);
            a.free(data.segments);
        },
        .branch => |data| {
            release(a, data.left);
            release(a, data.right);
        },
    }
    a.destroy(root);
}

pub fn leaf(a: Allocator, lines: []const Line, segments: []const Segment) !*Node {
    std.debug.assert(lines.len > 0 and lines.len <= leaf_lines);
    var total: Measure = .{};
    for (lines) |line| total = total.add(.line(line));
    std.debug.assert(total.rows == segments.len);
    const node = try a.create(Node);
    errdefer a.destroy(node);
    const owned_lines = try a.dupe(Line, lines);
    errdefer a.free(owned_lines);
    node.* = .{ .height = 1, .measure = total, .data = .{ .leaf = .{ .lines = owned_lines, .segments = try a.dupe(Segment, segments) } } };
    return node;
}

// Construction borrows inputs and returns an owned reference, including when
// the result is an existing node.
pub fn branch(a: Allocator, left: *Node, right: *Node) !*Node {
    const node = try a.create(Node);
    node.* = .{
        .height = 1 + @max(left.height, right.height),
        .measure = left.measure.add(right.measure),
        .data = .{ .branch = .{ .left = retain(left).?, .right = retain(right).? } },
    };
    return node;
}

fn balance(a: Allocator, left: *Node, right: *Node) !*Node {
    if (left.height > right.height + 1) {
        const child = left.data.branch;
        if (child.left.height >= child.right.height) {
            const tail = try branch(a, child.right, right);
            defer release(a, tail);
            return branch(a, child.left, tail);
        }
        const pivot = child.right.data.branch;
        const head = try branch(a, child.left, pivot.left);
        defer release(a, head);
        const tail = try branch(a, pivot.right, right);
        defer release(a, tail);
        return branch(a, head, tail);
    }
    if (right.height > left.height + 1) {
        const child = right.data.branch;
        if (child.right.height >= child.left.height) {
            const head = try branch(a, left, child.left);
            defer release(a, head);
            return branch(a, head, child.right);
        }
        const pivot = child.left.data.branch;
        const head = try branch(a, left, pivot.left);
        defer release(a, head);
        const tail = try branch(a, pivot.right, child.right);
        defer release(a, tail);
        return branch(a, head, tail);
    }
    return branch(a, left, right);
}

pub fn join(a: Allocator, left: ?*Node, right: ?*Node) Allocator.Error!?*Node {
    const l = left orelse return retain(right);
    const r = right orelse return retain(left);
    if (l.data == .leaf and r.data == .leaf and l.measure.lines + r.measure.lines <= leaf_lines and
        l.measure.rows + r.measure.rows <= leaf_lines * 4)
    {
        var lines: [leaf_lines]Line = undefined;
        var segments: [leaf_lines * 4]Segment = undefined;
        @memcpy(lines[0..l.measure.lines], l.data.leaf.lines);
        @memcpy(lines[l.measure.lines..][0..r.measure.lines], r.data.leaf.lines);
        @memcpy(segments[0..l.measure.rows], l.data.leaf.segments);
        @memcpy(segments[l.measure.rows..][0..r.measure.rows], r.data.leaf.segments);
        return try leaf(a, lines[0 .. l.measure.lines + r.measure.lines], segments[0 .. l.measure.rows + r.measure.rows]);
    }
    if (l.height > r.height + 1) {
        const tail = (try join(a, l.data.branch.right, r)).?;
        defer release(a, tail);
        return try balance(a, l.data.branch.left, tail);
    }
    if (r.height > l.height + 1) {
        const head = (try join(a, l, r.data.branch.left)).?;
        defer release(a, head);
        return try balance(a, head, r.data.branch.right);
    }
    return try branch(a, l, r);
}

pub fn slice(a: Allocator, node: ?*Node, start: usize, end: usize) Allocator.Error!?*Node {
    if (start == end) return null;
    const root = node.?;
    if (start == 0 and end == root.measure.lines) return retain(root);
    switch (root.data) {
        .leaf => |data| {
            var first: usize = 0;
            for (data.lines[0..start]) |line| first += line.rows;
            var last = first;
            for (data.lines[start..end]) |line| last += line.rows;
            return try leaf(a, data.lines[start..end], data.segments[first..last]);
        },
        .branch => |data| {
            const pivot = data.left.measure.lines;
            if (end <= pivot) return slice(a, data.left, start, end);
            if (start >= pivot) return slice(a, data.right, start - pivot, end - pivot);
            const left = try slice(a, data.left, start, pivot);
            defer release(a, left);
            const right = try slice(a, data.right, 0, end - pivot);
            defer release(a, right);
            return join(a, left, right);
        },
    }
}

pub const Row = struct { line: usize, start: usize, end: usize, x: f32, first: bool };

pub fn rowAt(root: *const Node, row: usize) Row {
    std.debug.assert(row < root.measure.rows);
    var node = root;
    var prefix: Measure = .{};
    while (node.data == .branch) {
        const data = node.data.branch;
        const pivot = prefix.add(data.left.measure);
        if (row < pivot.rows) {
            node = data.left;
        } else {
            prefix = pivot;
            node = data.right;
        }
    }
    const leaf_start = prefix.rows;
    for (node.data.leaf.lines) |line| {
        if (row - prefix.rows < line.rows) {
            const segment = node.data.leaf.segments[row - leaf_start];
            return .{ .line = prefix.lines, .start = prefix.bytes + segment.start, .end = prefix.bytes + segment.end, .x = segment.x, .first = row == prefix.rows };
        }
        prefix = prefix.add(.line(line));
    }
    unreachable;
}

pub fn rowStart(root: ?*const Node, line: usize) usize {
    var node = root orelse return 0;
    if (line >= node.measure.lines) return node.measure.rows;
    var prefix: Measure = .{};
    while (node.data == .branch) {
        const data = node.data.branch;
        const pivot = prefix.add(data.left.measure);
        if (line < pivot.lines) {
            node = data.left;
        } else {
            prefix = pivot;
            node = data.right;
        }
    }
    for (node.data.leaf.lines[0 .. line - prefix.lines]) |value| prefix.rows += value.rows;
    return prefix.rows;
}

const BytePosition = struct {
    prefix: Measure,
    segments: []const Segment,
};

fn seekByte(root: *const Node, offset: usize) BytePosition {
    var node = root;
    var prefix: Measure = .{};
    while (node.data == .branch) {
        const data = node.data.branch;
        const pivot = prefix.add(data.left.measure);
        if (offset < pivot.bytes) {
            node = data.left;
        } else {
            prefix = pivot;
            node = data.right;
        }
    }
    const leaf_start = prefix.rows;
    for (node.data.leaf.lines, 0..) |line, i| {
        if (offset < prefix.bytes + line.bytes or i + 1 == node.data.leaf.lines.len) {
            return .{ .prefix = prefix, .segments = node.data.leaf.segments[prefix.rows - leaf_start ..][0..line.rows] };
        }
        prefix = prefix.add(.line(line));
    }
    unreachable;
}

pub fn lineAtOffset(root: *const Node, offset: usize) usize {
    return seekByte(root, offset).prefix.lines;
}

pub fn rowAtOffset(root: *const Node, offset: usize) usize {
    const position = seekByte(root, offset);
    const relative = offset - position.prefix.bytes;
    var lo: usize = 0;
    var hi = position.segments.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (position.segments[mid].start <= relative) lo = mid + 1 else hi = mid;
    }
    return (position.prefix.rows + lo) -| 1;
}
