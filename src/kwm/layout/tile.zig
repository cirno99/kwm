const Self = @This();

const std = @import("std");
const log = std.log.scoped(.tiled);

const config = @import("config");

const types = @import("../types.zig");
const utils = @import("../utils.zig");
const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");

pub const MasterLocation = types.LayoutMasterLocation;

const ctx = Context.get();

nmaster: i32,
mfact: f32,
inner_gap: i32,
outer_gap: i32,
master_location: MasterLocation,

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

fn place(window: *Window, rect: Rect, outer_gap: i32) void {
    window.unbound_move(rect.x + outer_gap, rect.y + outer_gap);
    window.unbound_resize(@max(0, rect.w), @max(0, rect.h));
}

// 纯函数：计算主带 + 螺旋栈的窗口矩形（不含 outer_gap 偏移），与
// `arrange` 的原始实现逐行对应。regions 的长度即窗口数，顺序与
// `ctx.layout_windows` 一致。
fn computeRegions(
    regions: []Rect,
    nmaster_param: i32,
    mfact: f32,
    inner_gap: i32,
    usable_width: i32,
    usable_height: i32,
    master_location: MasterLocation,
) void {
    if (regions.len == 0) return;
    const window_num: i32 = @intCast(regions.len);
    const nmaster = @max(1, @min(window_num, nmaster_param));
    const nstack = window_num - nmaster;
    const master_num: usize = @intCast(nmaster);
    const stack_num: usize = @intCast(nstack);
    const half_gap = @divFloor(inner_gap, 2);

    const vertical = switch (master_location) {
        .left, .right => true,
        .top, .bottom => false,
    };

    var region = Rect{ .x = 0, .y = 0, .w = usable_width, .h = usable_height };

    // master band, split along the first direction
    if (vertical) {
        const band_w: i32 = if (nstack > 0)
            @intFromFloat(mfact * @as(f32, @floatFromInt(usable_width)))
        else
            usable_width;
        const master_h = @divFloor(usable_height, nmaster);
        const master_remain = @mod(usable_height, nmaster);
        const w = if (nstack > 0) band_w - half_gap else band_w;
        const x = switch (master_location) {
            .left => 0,
            .right => if (nstack > 0) usable_width - band_w + half_gap else usable_width - band_w,
            else => unreachable,
        };
        var y: i32 = 0;
        for (0..master_num) |m| {
            const h = (master_h + if (m == 0) master_remain else 0) - if (m > 0) inner_gap else 0;
            regions[m] = .{ .x = x, .y = y, .w = w, .h = h };
            y += h + if (m + 1 < master_num) inner_gap else 0;
        }
        if (nstack > 0) {
            region = switch (master_location) {
                .left => .{ .x = band_w + half_gap, .y = 0, .w = usable_width - band_w - half_gap, .h = usable_height },
                .right => .{ .x = 0, .y = 0, .w = usable_width - band_w - half_gap, .h = usable_height },
                else => unreachable,
            };
        }
    } else {
        const band_h: i32 = if (nstack > 0)
            @intFromFloat(mfact * @as(f32, @floatFromInt(usable_height)))
        else
            usable_height;
        const master_w = @divFloor(usable_width, nmaster);
        const master_remain = @mod(usable_width, nmaster);
        const h = if (nstack > 0) band_h - half_gap else band_h;
        const y = switch (master_location) {
            .top => 0,
            .bottom => if (nstack > 0) usable_height - band_h + half_gap else usable_height - band_h,
            else => unreachable,
        };
        var x: i32 = 0;
        for (0..master_num) |m| {
            const w = (master_w + if (m == 0) master_remain else 0) - if (m > 0) inner_gap else 0;
            regions[m] = .{ .x = x, .y = y, .w = w, .h = h };
            x += w + if (m + 1 < master_num) inner_gap else 0;
        }
        if (nstack > 0) {
            region = switch (master_location) {
                .top => .{ .x = 0, .y = band_h + half_gap, .w = usable_width, .h = usable_height - band_h - half_gap },
                .bottom => .{ .x = 0, .y = 0, .w = usable_width, .h = usable_height - band_h - half_gap },
                else => unreachable,
            };
        }
    }

    // spiral the remaining windows, alternating the split direction
    var next_vertical = !vertical;
    for (0..stack_num) |s| {
        const i = master_num + s;
        if (s == stack_num - 1) {
            regions[i] = region;
            break;
        }
        if (next_vertical) {
            const slice = @divFloor(region.w, 2);
            regions[i] = .{ .x = region.x, .y = region.y, .w = slice - half_gap, .h = region.h };
            region.x += slice + half_gap;
            region.w = @max(0, region.w - slice - half_gap);
        } else {
            const slice = @divFloor(region.h, 2);
            regions[i] = .{ .x = region.x, .y = region.y, .w = region.w, .h = slice - half_gap };
            region.y += slice + half_gap;
            region.h = @max(0, region.h - slice - half_gap);
        }
        next_vertical = !next_vertical;
    }
}

pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const windows = &ctx.layout_windows;
    try ctx.collect_layout_windows(output);

    if (windows.items.len == 0) return;

    const usable_width = @max(0, output.exclusive_width() - 2 * self.outer_gap);
    const usable_height = @max(0, output.exclusive_height() - 2 * self.outer_gap);

    // 从复用 arena 分配，避免每次排列都 malloc/free。
    const regions = ctx.layout_arena.allocator().alloc(Rect, windows.items.len) catch |err| {
        log.err("<{*}> alloc tile regions failed: {}", .{ self, err });
        return;
    };

    computeRegions(regions, self.nmaster, self.mfact, self.inner_gap, usable_width, usable_height, self.master_location);

    for (regions, windows.items) |region, window| {
        place(window, region, self.outer_gap);
    }
}

test "computeRegions 单窗口占满可用区域" {
    var regions: [1]Rect = undefined;
    computeRegions(&regions, 1, 0.5, 0, 1000, 800, .left);
    try std.testing.expectEqual(@as(i32, 0), regions[0].x);
    try std.testing.expectEqual(@as(i32, 0), regions[0].y);
    try std.testing.expectEqual(@as(i32, 1000), regions[0].w);
    try std.testing.expectEqual(@as(i32, 800), regions[0].h);
}

test "computeRegions master+stack 按 mfact 划分宽度" {
    var regions: [2]Rect = undefined;
    computeRegions(&regions, 1, 0.5, 0, 1000, 800, .left);
    try std.testing.expectEqual(@as(i32, 500), regions[0].w);
    try std.testing.expectEqual(@as(i32, 500), regions[1].x);
    try std.testing.expectEqual(@as(i32, 500), regions[1].w);
}

test "computeRegions right 主带贴右侧" {
    var regions: [2]Rect = undefined;
    computeRegions(&regions, 1, 0.5, 0, 1000, 800, .right);
    try std.testing.expectEqual(@as(i32, 500), regions[0].x);
    try std.testing.expectEqual(@as(i32, 0), regions[1].x);
}

test "computeRegions top 主带贴顶部" {
    var regions: [2]Rect = undefined;
    computeRegions(&regions, 1, 0.5, 0, 1000, 800, .top);
    try std.testing.expectEqual(@as(i32, 400), regions[0].h);
    try std.testing.expectEqual(@as(i32, 400), regions[1].y);
    try std.testing.expectEqual(@as(i32, 400), regions[1].h);
}

test "computeRegions 4 窗口螺旋栈交替分割方向" {
    var regions: [4]Rect = undefined;
    computeRegions(&regions, 1, 0.5, 0, 1000, 800, .left);
    // master: {0,0,500,800}；栈先水平切右半（regions[1]），
    // 再垂直切下半（regions[2]），最后一个拿剩余区域
    try std.testing.expectEqual(@as(i32, 400), regions[1].h);
    try std.testing.expectEqual(@as(i32, 0), regions[1].y);
    try std.testing.expectEqual(@as(i32, 250), regions[2].w);
    try std.testing.expectEqual(@as(i32, 400), regions[2].y);
    try std.testing.expectEqual(@as(i32, 750), regions[3].x);
    try std.testing.expectEqual(@as(i32, 250), regions[3].w);
    try std.testing.expectEqual(@as(i32, 400), regions[3].y);
}

test "computeRegions 多 master 均分高度并分配余数" {
    var regions: [3]Rect = undefined;
    computeRegions(&regions, 3, 0.5, 0, 1000, 800, .left);
    // 800/3 = 266 余 2，首个 master 拿到余数
    try std.testing.expectEqual(@as(i32, 268), regions[0].h);
    try std.testing.expectEqual(@as(i32, 0), regions[0].y);
    try std.testing.expectEqual(@as(i32, 268), regions[1].y);
    try std.testing.expectEqual(@as(i32, 266), regions[1].h);
    try std.testing.expectEqual(@as(i32, 534), regions[2].y);
    // 三个 master 高度之和为可用高度
    try std.testing.expectEqual(@as(i32, 800), regions[0].h + regions[1].h + regions[2].h);
}
