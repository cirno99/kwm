const Self = @This();

const std = @import("std");
const log = std.log.scoped(.scroller);

const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");
const types = @import("../types.zig");

const ctx = Context.get();

pub const Mode = enum {
    horizontal,
    vertical,
};

outer_gap: i32,
inner_gap: i32,
mfact: f32,
row_mfact: f32 = 1.0,
mode: Mode = .horizontal,

fn isTiled(window: *Window, output: *Output) bool {
    return window.is_visible_in(output) and !window.floating;
}

pub fn columnHead(window: *Window, output: *Output) *Window {
    if (window.scroller_column_start) return window;
    var win = window;
    while (win.link.prev.? != &ctx.windows.link) {
        const prev: *Window = @fieldParentPtr("link", win.link.prev.?);
        win = prev;
        if (isTiled(prev, output) and prev.scroller_column_start) break;
    }
    return win;
}

pub fn columnTail(window: *Window, output: *Output) *Window {
    var win = window;
    while (win.link.next.? != &ctx.windows.link) {
        const next: *Window = @fieldParentPtr("link", win.link.next.?);
        if (isTiled(next, output) and next.scroller_column_start) break;
        win = next;
    }
    return win;
}

// The first tiled window in the list acts as the head of the first column even
// without an explicit column-start marker (e.g. windows stacked in vertical
// mode), so a column never becomes unreachable from an adjacent one.
pub fn prevColumn(head: *Window, output: *Output) ?*Window {
    var link = &head.link;
    var implicit: ?*Window = null;
    while (link.prev.? != &ctx.windows.link) {
        link = link.prev.?;
        const w: *Window = @fieldParentPtr("link", link);
        if (!isTiled(w, output)) continue;
        implicit = w;
        if (w.scroller_column_start) return w;
    }
    return implicit;
}

pub fn nextColumn(tail: *Window, output: *Output) ?*Window {
    var link = &tail.link;
    var implicit: ?*Window = null;
    while (link.next.? != &ctx.windows.link) {
        link = link.next.?;
        const w: *Window = @fieldParentPtr("link", link);
        if (!isTiled(w, output)) continue;
        if (implicit == null) implicit = w;
        if (w.scroller_column_start) return w;
    }
    return implicit;
}

fn columnWidth(head: *Window, available_width: i32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(available_width)) * head.scroller_mfact);
}

// Navigate to the window above (`.reverse`) or below (`.forward`) `window`
// within the same column. Returns null when there is no such window.
pub fn columnWindow(window: *Window, output: *Output, direction: types.Direction) ?*Window {
    const head = columnHead(window, output);
    var link = &window.link;
    switch (direction) {
        .forward => {
            while (link.next.? != &ctx.windows.link) {
                link = link.next.?;
                const w: *Window = @fieldParentPtr("link", link);
                if (!isTiled(w, output)) continue;
                if (w.scroller_column_start) break;
                return w;
            }
            return null;
        },
        .reverse => {
            if (window == head) return null;
            while (link.prev.? != &ctx.windows.link) {
                link = link.prev.?;
                const w: *Window = @fieldParentPtr("link", link);
                if (!isTiled(w, output)) continue;
                return w;
            }
            return null;
        },
    }
}

// Remember `window` as the focused window of its column, stored on the column
// head so it can be restored when focus returns from an adjacent column.
pub fn rememberColumnFocus(window: *Window, output: *Output) void {
    columnHead(window, output).scroller_column_focus = window;
}

// The window to focus in a column: the previously focused window if it is still
// a tiled window of the column, otherwise the column head.
pub fn columnFocusTarget(head: *Window, output: *Output) *Window {
    if (head.scroller_column_focus) |remembered| {
        if (remembered != head and isTiled(remembered, output) and columnHead(remembered, output) == head) {
            return remembered;
        }
    }
    return head;
}

// Focus the adjacent column to the left: remember the currently focused window
// of the current column and restore the previously focused window of the
// target column when available.
pub fn prevColumnFocus(window: *Window, output: *Output) ?*Window {
    rememberColumnFocus(window, output);
    const prev = prevColumn(columnHead(window, output), output) orelse return null;
    return columnFocusTarget(prev, output);
}

// Focus the adjacent column to the right: remember the currently focused window
// of the current column and restore the previously focused window of the
// target column when available.
pub fn nextColumnFocus(window: *Window, output: *Output) ?*Window {
    rememberColumnFocus(window, output);
    const next = nextColumn(columnTail(window, output), output) orelse return null;
    return columnFocusTarget(next, output);
}

// Insert `window` into the window list without splitting the focused window's
// column: a new column head is placed at the edge of the focused column (to
// its left for `.above_focused`, to its right for `.below_focused`), while a
// window joining an existing column is placed right next to the focused
// window.
pub fn attach(
    window: *Window,
    focused: ?*Window,
    output: *Output,
    mode: types.WindowAttachMode,
) void {
    switch (mode) {
        .top => ctx.windows.prepend(window),
        .bottom => ctx.windows.append(window),
        .above_focused, .below_focused => {
            const focus = focused orelse {
                ctx.windows.prepend(window);
                return;
            };
            const anchor = if (window.scroller_column_start and isTiled(focus, output))
                switch (mode) {
                    .above_focused => columnHead(focus, output),
                    .below_focused => columnTail(focus, output),
                    else => unreachable,
                }
            else
                focus;
            switch (mode) {
                .above_focused => anchor.link.prev.?.insert(&window.link),
                .below_focused => anchor.link.insert(&window.link),
                else => unreachable,
            }
        },
        else => ctx.windows.prepend(window), // .stack_top
    }
}

// Swap the list positions of `a` and `b` while keeping the column boundaries
// at their list positions, so swapping never splits or merges columns.
pub fn swap(a: *Window, b: *Window) void {
    if (a.scroller_column_start != b.scroller_column_start) {
        const tmp = a.scroller_column_start;
        a.scroller_column_start = b.scroller_column_start;
        b.scroller_column_start = tmp;
    }
    a.link.swapWith(&b.link);
}

fn rowHeight(window: *Window, available_height: i32, outer_gap: i32) i32 {
    const usable = @max(0, available_height - 2 * outer_gap);
    return @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(usable)) * window.scroller_row_mfact)));
}

// Lay out a single column. Windows are stacked vertically, the focused window
// (or, for a non-focused column, its last focused window) is anchored at the
// vertical center and the rest overflow above and below, so a column can grow
// without being limited by the output height.
fn arrangeColumn(
    output: *Output,
    head: *Window,
    x: i32,
    width: i32,
    focused: ?*Window,
    available_height: i32,
    outer_gap: i32,
    inner_gap: i32,
) void {
    const anchor = focused orelse head;
    const anchor_height = rowHeight(anchor, available_height, outer_gap);
    const anchor_y = @divFloor(available_height - anchor_height, 2);
    anchor.unbound_move(x, anchor_y);
    anchor.unbound_resize(width, anchor_height);

    var y = anchor_y + anchor_height + inner_gap;

    var link = &anchor.link;
    while (link.next.? != &ctx.windows.link) {
        link = link.next.?;
        const w: *Window = @fieldParentPtr("link", link);
        if (!isTiled(w, output)) continue;
        if (w.scroller_column_start) break;
        const h = rowHeight(w, available_height, outer_gap);
        w.unbound_move(x, y);
        w.unbound_resize(width, h);
        y += h + inner_gap;
    }

    if (anchor != head) {
        var y_up = anchor_y - inner_gap;
        link = &anchor.link;
        while (true) {
            if (link.prev.? == &ctx.windows.link) break;
            link = link.prev.?;
            const w: *Window = @fieldParentPtr("link", link);
            if (!isTiled(w, output)) continue;
            const h = rowHeight(w, available_height, outer_gap);
            y_up -= h;
            w.unbound_move(x, y_up);
            w.unbound_resize(width, h);
            y_up -= inner_gap;
            if (w == head) break;
        }
    }
}

pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const focus_top = ctx.focus_top_in(output, true) orelse return;

    const available_width = output.exclusive_width();
    const available_height = output.exclusive_height();
    const outer_gap = self.outer_gap;
    const inner_gap = self.inner_gap;

    const head = columnHead(focus_top, output);
    const tail = columnTail(focus_top, output);

    const master_width = columnWidth(head, available_width);
    const right = output.width - outer_gap - master_width;
    const master_x = blk: {
        const x = if (head.scroller_x) |scroller_x| switch (scroller_x) {
            .x => |x| x,
            .center => break :blk @divFloor(output.width - master_width, 2),
        } else outer_gap;
        break :blk @min(@max(x, outer_gap), right);
    };
    if (head.scroller_x == null or head.scroller_x.? == .x) {
        head.scroller_x = .{ .x = master_x };
    }

    arrangeColumn(output, head, master_x, master_width, focus_top, available_height, outer_gap, inner_gap);

    var col_x = master_x;
    var col = head;
    while (true) {
        const prev = prevColumn(col, output) orelse break;
        const width = columnWidth(prev, available_width);
        col_x -= inner_gap + width;
        prev.scroller_x = .{ .x = col_x };
        arrangeColumn(output, prev, col_x, width, columnFocusTarget(prev, output), available_height, outer_gap, inner_gap);
        col = prev;
    }

    col_x = master_x + master_width;
    col = tail;
    while (true) {
        const next = nextColumn(col, output) orelse break;
        const width = columnWidth(next, available_width);
        col_x += inner_gap;
        next.scroller_x = .{ .x = col_x };
        arrangeColumn(output, next, col_x, width, columnFocusTarget(next, output), available_height, outer_gap, inner_gap);
        col_x += width;
        col = next;
    }
}
