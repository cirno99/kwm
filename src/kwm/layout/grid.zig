const Self = @This();

const std = @import("std");
const log = std.log.scoped(.grid);

const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");

pub const Direction = enum {
    horizontal,
    vertical,
};

const ctx = Context.get();

outer_gap: i32,
inner_gap: i32,
direction: Direction,

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

// 纯函数：计算第 i 个窗口在水平方向坐标系下的矩形（不含 outer_gap 偏移），
// 与 `arrange` 的原始实现逐行对应；`.vertical` 方向由调用方交换 x/y、w/h。
fn cellRect(
    i: usize,
    col_num: i32,
    row_num: i32,
    width: i32,
    height: i32,
    width_remain: i32,
    height_remain: i32,
    inner_gap: i32,
    last_row_pad: i32,
) Rect {
    const row: i32 = @divFloor(@as(i32, @intCast(i)), col_num);
    const col: i32 = @as(i32, @intCast(i)) - row * col_num;

    const x = col * width + (if (col > 0) width_remain else 0) + if (row == row_num - 1) last_row_pad else 0;
    const y = row * height + if (row > 0) inner_gap + height_remain else 0;
    const w = width - (if (col < col_num - 1) inner_gap else 0) + if (col == 0) width_remain else 0;
    const h = height - (if (row > 0) inner_gap else 0) + if (row == 0) height_remain else 0;
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const windows = &ctx.layout_windows;
    try ctx.collect_layout_windows(output);

    if (windows.items.len == 0) return;

    const col_num: i32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(windows.items.len)))));
    const row_num: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(windows.items.len)) / @as(f32, @floatFromInt(col_num))));
    const available_width, const available_height = blk: {
        const width = @max(0, output.exclusive_width() - 2 * self.outer_gap);
        const height = @max(0, output.exclusive_height() - 2 * self.outer_gap);
        break :blk switch (self.direction) {
            .horizontal => .{ width, height },
            .vertical => .{ height, width },
        };
    };

    const width = @divFloor(available_width, col_num);
    const width_remain = @mod(available_width, col_num);
    const height = @divFloor(available_height, row_num);
    const height_remain = @mod(available_height, row_num);

    const space_width = (row_num * col_num - @as(i32, @intCast(windows.items.len))) * width;
    const last_row_pad = @divFloor(space_width, 2) + @mod(space_width, 2);
    for (0.., windows.items) |i, window| {
        const rect = cellRect(
            i,
            col_num,
            row_num,
            width,
            height,
            width_remain,
            height_remain,
            self.inner_gap,
            last_row_pad,
        );

        switch (self.direction) {
            .horizontal => {
                window.unbound_move(rect.x + self.outer_gap, rect.y + self.outer_gap);
                window.unbound_resize(rect.w, rect.h);
            },
            .vertical => {
                window.unbound_move(rect.y + self.outer_gap, rect.x + self.outer_gap);
                window.unbound_resize(rect.h, rect.w);
            },
        }
    }
}

test "cellRect 4 窗口 2x2 均分" {
    // 1000x800，无 gap：col=2, row=2, cell 500x400，余数为 0
    const expectRect = std.testing.expectEqual;
    try expectRect(@as(i32, 0), cellRect(0, 2, 2, 500, 400, 0, 0, 0, 0).x);
    try expectRect(@as(i32, 500), cellRect(1, 2, 2, 500, 400, 0, 0, 0, 0).x);
    try expectRect(@as(i32, 400), cellRect(2, 2, 2, 500, 400, 0, 0, 0, 0).y);
    try expectRect(@as(i32, 500), cellRect(3, 2, 2, 500, 400, 0, 0, 0, 0).x);
}

test "cellRect 3 窗口末行居中" {
    // col=2, row=2：末行只有 1 个窗口，space_width=500，pad=250 居中
    const cell = cellRect(2, 2, 2, 500, 400, 0, 0, 0, 250);
    try std.testing.expectEqual(@as(i32, 250), cell.x);
    try std.testing.expectEqual(@as(i32, 400), cell.y);
}

test "cellRect 余数分配到首行首列" {
    // 1000/3 = 333 余 1：第一列的窗口宽度 +1（334），后续列 x 偏移 +1
    const first = cellRect(0, 3, 1, 333, 400, 1, 0, 0, 0);
    try std.testing.expectEqual(@as(i32, 0), first.x);
    try std.testing.expectEqual(@as(i32, 334), first.w);
    const second = cellRect(1, 3, 1, 333, 400, 1, 0, 0, 0);
    try std.testing.expectEqual(@as(i32, 334), second.x);
    try std.testing.expectEqual(@as(i32, 333), second.w);
    // 一行之和等于可用宽度
    try std.testing.expectEqual(@as(i32, 1000), first.w + second.w + cellRect(2, 3, 1, 333, 400, 1, 0, 0, 0).w);
}

test "cellRect 行间计入 inner_gap 与高度余数" {
    // row>0 时 y 加 inner_gap + height_remain，h 相应减去
    const below = cellRect(3, 2, 2, 500, 400, 0, 2, 10, 0);
    try std.testing.expectEqual(@as(i32, 412), below.y);
    try std.testing.expectEqual(@as(i32, 390), below.h);
}
