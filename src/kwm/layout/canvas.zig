const Self = @This();

const std = @import("std");
const log = std.log.scoped(.canvas);

const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");
const types = @import("../types.zig");

const ctx = Context.get();

// 新窗口默认最小尺寸（客户端尚未报告尺寸时使用）
const default_width = 640;
const default_height = 480;

outer_gap: i32,
inner_gap: i32,
// 相机偏移：画布坐标原点在屏幕上的位置。窗口渲染位置 = 画布坐标 - 相机偏移。
cam_x: i32 = 0,
cam_y: i32 = 0,
// flex 排列状态：true 时窗口按创建顺序 flex 排列，再次触发还原。
flex_active: bool = false,

fn isTiled(window: *Window, output: *Output) bool {
    return window.is_visible_in(output) and !window.floating and !window.sticky;
}

// 将新窗口放置在相机中心附近，重置为默认尺寸。
// 从其他布局（如 tile）切换过来时窗口可能是全屏尺寸，必须重置，
// 否则多个窗口会完全叠在一起，方向导航也找不到目标。
// 基于窗口在列表中的索引加 8 方向偏移，避免多个窗口完全叠放。
fn placeNewWindow(self: *const Self, window: *Window, output: *Output) void {
    window.unbound_resize(default_width, default_height);

    var index: i32 = 0;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |w| {
        if (w == window) break;
        if (isTiled(w, output)) index += 1;
    }
    const offset: i32 = 60;
    const dx, const dy = switch (@rem(index, 8)) {
        0 => .{ 0, 0 },
        1 => .{ offset, 0 },
        2 => .{ offset, offset },
        3 => .{ 0, offset },
        4 => .{ -offset, offset },
        5 => .{ -offset, 0 },
        6 => .{ -offset, -offset },
        else => .{ 0, -offset },
    };

    window.canvas_x = self.cam_x + @divFloor(output.width - default_width, 2) + dx;
    window.canvas_y = self.cam_y + @divFloor(output.height - default_height, 2) + dy;
}

pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });
    if (self.flex_active) {
        // flex 排列状态下：
        // - 有新窗口（尚无画布坐标）时：补存快照并重新应用排列，新窗口参与排列；
        // - 无新窗口时：仅按画布坐标渲染，窗口保持 flex 排列位置，相机可自由平移。
        var has_new = false;
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!isTiled(window, output)) continue;
            if (window.canvas_x == null or window.canvas_y == null) {
                has_new = true;
                break;
            }
        }
        if (has_new) {
            self.saveNewWindows(output);
            try self.applyFlex(output);
            return;
        }
        it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!isTiled(window, output)) continue;
            const rx = window.canvas_x.? - self.cam_x;
            const ry = window.canvas_y.? - self.cam_y;
            window.unbound_move(rx, ry);
        }
        return;
    }

    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!isTiled(window, output)) continue;
        // 首次放置，或从其他布局切换回来时窗口被 resize 成全屏尺寸（>= 输出尺寸），
        // 都重置为默认尺寸并居中，避免窗口叠放。
        if (window.canvas_x == null or window.canvas_y == null or
            window.width >= output.width or window.height >= output.height)
        {
            placeNewWindow(self, window, output);
        }
        const rx = window.canvas_x.? - self.cam_x;
        const ry = window.canvas_y.? - self.cam_y;
        window.unbound_move(rx, ry);
    }
}

// 窗口中心坐标（纯函数导航测试用）
const Center = struct { x: i32, y: i32 };

// 在画布坐标上找 `window` 指定方向最近的窗口（按窗口中心比较，曼哈顿距离）。
pub fn navigate(self: *const Self, window: *Window, output: *Output, direction: types.WindowDirection) ?*Window {
    _ = self;
    const fx = window.canvas_x.? + @divFloor(window.width, 2);
    const fy = window.canvas_y.? + @divFloor(window.height, 2);

    var best: ?*Window = null;
    var best_dist: i64 = std.math.maxInt(i64);

    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |w| {
        if (w == window) continue;
        if (!isTiled(w, output)) continue;
        const cx = w.canvas_x.? + @divFloor(w.width, 2);
        const cy = w.canvas_y.? + @divFloor(w.height, 2);

        const in_direction = switch (direction) {
            .left => cx < fx,
            .right => cx > fx,
            .up => cy < fy,
            .down => cy > fy,
        };
        if (!in_direction) continue;

        const dist: i64 = @intCast(@abs(@as(i64, cx) - fx) + @abs(@as(i64, cy) - fy));
        if (dist < best_dist) {
            best_dist = dist;
            best = w;
        }
    }
    return best;
}

// 平移相机（dx/dy 为屏幕像素偏移）。
pub fn pan(self: *Self, dx: i32, dy: i32) void {
    self.cam_x += dx;
    self.cam_y += dy;
}

// 将相机居中到窗口中心。
pub fn centerOn(self: *Self, window: *Window, output: *Output) void {
    self.cam_x = window.canvas_x.? + @divFloor(window.width, 2) - @divFloor(output.width, 2);
    self.cam_y = window.canvas_y.? + @divFloor(window.height, 2) - @divFloor(output.height, 2);
}

// 拖拽钳制结果：钳制后的期望渲染坐标，以及为跟随指针而移动相机的偏移量。
const DragClamp = struct {
    rx: i32,
    ry: i32, 
    cam_dx: i32,
    cam_dy: i32,
};

// 拖拽钳制（纯函数，便于测试）：仅允许窗口在当前 output 可视范围内移动（无限画布概念，
// 拖到屏幕边缘不跨屏），超出屏幕边缘的部分转为相机平移，实现"拖边即滚动画布"。
//
// rx/ry 为指针移动后期望的窗口渲染坐标（窗口画布坐标 - 相机偏移）；
// 钳制范围：[outer_gap, output.width - window.width - outer_gap]（y 同理）；
// cam_dx/cam_dy 为相机需追加的平移量：钳制发生时，超出量即相机应跟随移动的距离，
// 使窗口画布坐标保持与指针 1:1（被拖窗口贴边，其余窗口随相机滑过视野）。
// 窗口宽/高不小于输出（或输出过小）时钳制区间为空，返回钳制到左上边缘的结果。
pub fn dragClamp(rx: i32, ry: i32, window_width: i32, window_height: i32, output_width: i32, output_height: i32, outer_gap: i32) DragClamp {
    // x 轴：钳制到 [outer_gap, output.width - window.width - outer_gap]
    const min_x = outer_gap;
    const max_x = output_width - window_width - outer_gap;
    const clamped_rx = @min(@max(rx, min_x), @max(max_x, min_x));
    const cam_dx = rx - clamped_rx;
    // y 轴：钳制到 [outer_gap, output.height - window.height - outer_gap]
    const min_y = outer_gap;
    const max_y = output_height - window_height - outer_gap;
    const clamped_ry = @min(@max(ry, min_y), @max(max_y, min_y));
    const cam_dy = ry - clamped_ry;
    return .{ .rx = clamped_rx, .ry = clamped_ry, .cam_dx = cam_dx, .cam_dy = cam_dy };
}

test "dragClamp 屏幕内正常拖动不移动相机" {
    // 1000×800 输出，400×300 窗口，outer_gap=10：x∈[10,590]，y∈[10,490]
    const result = dragClamp(100, 200, 400, 300, 1000, 800, 10);
    try std.testing.expectEqual(@as(i32, 100), result.rx);
    try std.testing.expectEqual(@as(i32, 200), result.ry);
    try std.testing.expectEqual(@as(i32, 0), result.cam_dx);
    try std.testing.expectEqual(@as(i32, 0), result.cam_dy);
}

test "dragClamp 拖出右/下边缘钳制并右/下移相机" {
    const result = dragClamp(700, 600, 400, 300, 1000, 800, 10);
    try std.testing.expectEqual(@as(i32, 590), result.rx);
    try std.testing.expectEqual(@as(i32, 490), result.ry);
    try std.testing.expectEqual(@as(i32, 110), result.cam_dx);
    try std.testing.expectEqual(@as(i32, 110), result.cam_dy);
}

test "dragClamp 拖出左/上边缘钳制并左/上移相机" {
    const result = dragClamp(-50, -30, 400, 300, 1000, 800, 10);
    try std.testing.expectEqual(@as(i32, 10), result.rx);
    try std.testing.expectEqual(@as(i32, 10), result.ry);
    try std.testing.expectEqual(@as(i32, -60), result.cam_dx);
    try std.testing.expectEqual(@as(i32, -40), result.cam_dy);
}

test "dragClamp 窗口不小于输出时钳到左上边缘" {
    // 窗口 1200×900 大于输出 1000×800：max < min，取 min
    const result = dragClamp(500, 500, 1200, 900, 1000, 800, 10);
    try std.testing.expectEqual(@as(i32, 10), result.rx);
    try std.testing.expectEqual(@as(i32, 10), result.ry);
    try std.testing.expectEqual(@as(i32, 490), result.cam_dx);
    try std.testing.expectEqual(@as(i32, 490), result.cam_dy);
}

// ---- flex 排列（参考 photo-flex-layout，按窗口创建顺序组织） ----

// flex 排列结果：相对排列原点的画布坐标与尺寸。
const FlexBox = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

// photo-flex-layout 算法移植：
// 输入窗口宽高比列表，用最短路径（DAG 动态规划）将窗口分成若干行，
// 每行高度 = 行宽 / Σ行内宽高比，使各行高度尽量接近 target_row_height。
// 返回每个窗口相对排列原点的 (x, y, width, height)。
fn flexLayout(
    ratios: []const f32,
    container_width: i32,
    target_row_height: i32,
    spacing: i32,
    allocator: std.mem.Allocator,
) ![]FlexBox {
    const n = ratios.len;
    const boxes = try allocator.alloc(FlexBox, n);
    if (n == 0) return boxes;

    // 限制单行最多窗口数（参考实现：containerWidth > 500 时按比例估算）
    const limit: usize = if (container_width > 500)
        @intCast(@divTrunc(@divTrunc(container_width, target_row_height) * 2, 3) + 8)
    else
        5;

    // 行高：行内窗口共享同一高度，宽度 = 高度 × 宽高比
    const calcCommonHeight = struct {
        fn f(rs: []const f32, start: usize, end: usize, cw: i32, sp: i32) f32 {
            var sum: f32 = 0;
            for (rs[start..end]) |r| sum += r;
            const count: f32 = @floatFromInt(end - start);
            const row_width: f32 = @as(f32, @floatFromInt(cw)) - count * @as(f32, @floatFromInt(sp));
            return row_width / sum;
        }
    }.f;

    // DAG 最短路径：节点 0..n，边 (start, end) 权重 = (行高 - target)²。
    // dist[i] = 从 0 到 i 的最小累计代价，prev[i] = 最优路径前驱。
    const dist = try allocator.alloc(f32, n + 1);
    defer allocator.free(dist);
    const prev = try allocator.alloc(usize, n + 1);
    defer allocator.free(prev);
    for (dist) |*d| d.* = std.math.inf(f32);
    dist[0] = 0;
    for (1..n + 1) |end| {
        const start_min = if (end > limit) end - limit else 0;
        for (start_min..end) |start| {
            const h = calcCommonHeight(ratios, start, end, container_width, spacing);
            const diff = h - @as(f32, @floatFromInt(target_row_height));
            const cost = diff * diff;
            if (dist[start] + cost < dist[end]) {
                dist[end] = dist[start] + cost;
                prev[end] = start;
            }
        }
    }

    // 回溯行分割点（逆序），反转得到 [0, r1, r2, ..., n]
    var rows = std.ArrayListUnmanaged(usize).empty;
    defer rows.deinit(allocator);
    var node = n;
    while (true) {
        try rows.append(allocator, node);
        if (node == 0) break;
        node = prev[node];
    }
    std.mem.reverse(usize, rows.items);

    // 逐行布局
    var top: i32 = 0;
    var row_index: usize = 0;
    while (row_index + 1 < rows.items.len) : (row_index += 1) {
        const start = rows.items[row_index];
        const end = rows.items[row_index + 1];
        var h = calcCommonHeight(ratios, start, end, container_width, spacing);
        // 最后一行若过高则压到 target_row_height（参考实现）
        if (end == n and h > @as(f32, @floatFromInt(target_row_height)) * 1.3) {
            h = @floatFromInt(target_row_height);
        }
        const height: i32 = @intFromFloat(@round(h));
        var left: i32 = 0;
        for (ratios[start..end], start..end) |r, i| {
            const w: i32 = @intFromFloat(@round(h * r));
            boxes[i] = .{ .x = left, .y = top, .width = w, .height = height };
            left += w + spacing;
        }
        top += height + spacing;
    }
    return boxes;
}

// 保存所有 tiled 窗口当前画布位置与尺寸到快照（排列前原始状态）。
fn saveFlex(self: *const Self, output: *Output) void {
    _ = self;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!isTiled(window, output)) continue;
        window.flex_saved = .{
            .x = window.canvas_x orelse 0,
            .y = window.canvas_y orelse 0,
            .width = window.width,
            .height = window.height,
        };
    }
}

// flex 状态下为新窗口（无快照）保存当前位置，保证还原时能恢复。
fn saveNewWindows(self: *const Self, output: *Output) void {
    _ = self;
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!isTiled(window, output)) continue;
        if (window.flex_saved == null) {
            window.flex_saved = .{
                .x = window.canvas_x orelse 0,
                .y = window.canvas_y orelse 0,
                .width = window.width,
                .height = window.height,
            };
        }
    }
}

// 还原快照：恢复窗口原始画布位置与尺寸。
fn restoreFlex(self: *const Self, output: *Output) void {
    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!isTiled(window, output)) continue;
        if (window.flex_saved) |saved| {
            window.canvas_x = saved.x;
            window.canvas_y = saved.y;
            window.unbound_resize(saved.width, saved.height);
            window.unbound_move(saved.x - self.cam_x, saved.y - self.cam_y);
            window.flex_saved = null;
        }
    }
}

// 应用 flex 排列：按窗口列表顺序（创建顺序）排列所有 tiled 窗口。
// 排列原点为当前相机位置，窗口落在视野内。
// 只改变窗口位置，不改变窗口尺寸：用 flexLayout 的分行信息（box.y 相同的窗口为同一行），
// 每行内窗口保持自身宽高，按创建顺序从左到右依次摆放。
fn applyFlex(self: *const Self, output: *Output) !void {
    var windows = std.ArrayListUnmanaged(*Window).empty;
    defer windows.deinit(ctx.gpa);
    var ratios = std.ArrayListUnmanaged(f32).empty;
    defer ratios.deinit(ctx.gpa);

    var it = ctx.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!isTiled(window, output)) continue;
        try windows.append(ctx.gpa, window);
        const w: f32 = @floatFromInt(if (window.width > 0) window.width else default_width);
        const h: f32 = @floatFromInt(if (window.height > 0) window.height else default_height);
        try ratios.append(ctx.gpa, w / h);
    }

    const container_width = output.width - 2 * self.outer_gap;
    const target_row_height = @divTrunc(output.height * 3, 5); // 60% 输出高度
    const boxes = try flexLayout(ratios.items, container_width, target_row_height, self.inner_gap, ctx.gpa);
    defer ctx.gpa.free(boxes);

    // 分行：box.y 相同的窗口为同一行；行内窗口保持自身尺寸，从左到右依次摆放。
    var row_top: i32 = 0;
    var i: usize = 0;
    while (i < windows.items.len) {
        const row_y = boxes[i].y;
        var col_x: i32 = 0;
        var row_max_h: i32 = 0;
        while (i < windows.items.len and boxes[i].y == row_y) : (i += 1) {
            const window = windows.items[i];
            const w = if (window.width > 0) window.width else default_width;
            const h = if (window.height > 0) window.height else default_height;
            window.canvas_x = self.cam_x + col_x;
            window.canvas_y = self.cam_y + row_top;
            window.unbound_move(col_x, row_top);
            col_x += w + self.inner_gap;
            if (h > row_max_h) row_max_h = h;
        }
        row_top += row_max_h + self.inner_gap;
    }
}

// toggle flex 排列：第一次触发排列，第二次触发还原。
pub fn toggleFlex(self: *Self, output: *Output) void {
    if (self.flex_active) {
        self.restoreFlex(output);
        self.flex_active = false;
    } else {
        self.saveFlex(output);
        self.flex_active = true;
        self.applyFlex(output) catch |err| {
            log.err("flex layout failed: {}", .{err});
            self.restoreFlex(output);
            self.flex_active = false;
        };
    }
}
// 纯函数导航核心：给定窗口中心坐标列表，返回 `focus` 指定方向最近的索引。
// 与 navigate 共享同一算法，便于单元测试（不依赖全局 ctx）。
fn navigateIndex(
    centers: []const Center,
    focus: usize,
    direction: types.WindowDirection,
) ?usize {
    const fx = centers[focus].x;
    const fy = centers[focus].y;
    var best: ?usize = null;
    var best_dist: i64 = std.math.maxInt(i64);
    for (centers, 0..) |c, i| {
        if (i == focus) continue;
        const in_direction = switch (direction) {
            .left => c.x < fx,
            .right => c.x > fx,
            .up => c.y < fy,
            .down => c.y > fy,
        };
        if (!in_direction) continue;
        const dist: i64 = @intCast(@abs(@as(i64, c.x) - fx) + @abs(@as(i64, c.y) - fy));
        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
    }
    return best;
}

test "navigate 选择指定方向最近窗口" {
    const centers = [_]Center{
        .{ .x = 0, .y = 0 },    // 0 焦点
        .{ .x = 100, .y = 0 },  // 1 右（近）
        .{ .x = -100, .y = 0 }, // 2 左
        .{ .x = 0, .y = 100 },  // 3 下
        .{ .x = 0, .y = -100 }, // 4 上
        .{ .x = 200, .y = 10 }, // 5 右（远）
    };
    try std.testing.expectEqual(@as(?usize, 1), navigateIndex(&centers, 0, .right));
    try std.testing.expectEqual(@as(?usize, 2), navigateIndex(&centers, 0, .left));
    try std.testing.expectEqual(@as(?usize, 3), navigateIndex(&centers, 0, .down));
    try std.testing.expectEqual(@as(?usize, 4), navigateIndex(&centers, 0, .up));
}

test "navigate 方向无目标返回 null" {
    const centers = [_]Center{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
    };
    try std.testing.expectEqual(@as(?usize, null), navigateIndex(&centers, 0, .left));
    try std.testing.expectEqual(@as(?usize, null), navigateIndex(&centers, 0, .up));
    try std.testing.expectEqual(@as(?usize, 1), navigateIndex(&centers, 0, .right));
}

test "flexLayout 空列表返回空" {
    const boxes = try flexLayout(&[_]f32{}, 1000, 400, 10, std.testing.allocator);
    defer std.testing.allocator.free(boxes);
    try std.testing.expectEqual(@as(usize, 0), boxes.len);
}

test "flexLayout 单窗口占满整行并压到目标行高" {
    // 单窗口：行高 = (1000-10)/1 = 990 > 400×1.3，最后一行压到 400
    const ratios = [_]f32{ 1.0 };
    const boxes = try flexLayout(&ratios, 1000, 400, 10, std.testing.allocator);
    defer std.testing.allocator.free(boxes);
    try std.testing.expectEqual(@as(usize, 1), boxes.len);
    try std.testing.expectEqual(@as(i32, 0), boxes[0].x);
    try std.testing.expectEqual(@as(i32, 0), boxes[0].y);
    try std.testing.expectEqual(@as(i32, 400), boxes[0].width);
    try std.testing.expectEqual(@as(i32, 400), boxes[0].height);
}

test "flexLayout 4 个 1:1 窗口分成 2+2 两行" {
    // 2+2：行高 (1000-20)/2 = 490，代价 8100×2；3+1 代价远大于此，DP 选 2+2
    const ratios = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const boxes = try flexLayout(&ratios, 1000, 400, 10, std.testing.allocator);
    defer std.testing.allocator.free(boxes);
    try std.testing.expectEqual(@as(usize, 4), boxes.len);
    // 第一行
    try std.testing.expectEqual(@as(i32, 0), boxes[0].x);
    try std.testing.expectEqual(@as(i32, 0), boxes[0].y);
    try std.testing.expectEqual(@as(i32, 490), boxes[0].width);
    try std.testing.expectEqual(@as(i32, 490), boxes[0].height);
    try std.testing.expectEqual(@as(i32, 500), boxes[1].x);
    try std.testing.expectEqual(@as(i32, 0), boxes[1].y);
    // 第二行
    try std.testing.expectEqual(@as(i32, 0), boxes[2].x);
    try std.testing.expectEqual(@as(i32, 500), boxes[2].y);
    try std.testing.expectEqual(@as(i32, 500), boxes[3].x);
    try std.testing.expectEqual(@as(i32, 500), boxes[3].y);
}

test "flexLayout 3 个 1:1 窗口分成一行" {
    // 3 个一行：行高 (1000-30)/3 = 323.3，代价 5881；2+1 代价远大于此，DP 选 3
    const ratios = [_]f32{ 1.0, 1.0, 1.0 };
    const boxes = try flexLayout(&ratios, 1000, 400, 10, std.testing.allocator);
    defer std.testing.allocator.free(boxes);
    try std.testing.expectEqual(@as(usize, 3), boxes.len);
    try std.testing.expectEqual(@as(i32, 0), boxes[0].x);
    try std.testing.expectEqual(@as(i32, 0), boxes[0].y);
    try std.testing.expectEqual(@as(i32, 323), boxes[0].width);
    try std.testing.expectEqual(@as(i32, 323), boxes[0].height);
    try std.testing.expectEqual(@as(i32, 333), boxes[1].x);
    try std.testing.expectEqual(@as(i32, 666), boxes[2].x);
}

test "flexLayout 不同宽高比按比例分配宽度" {
    // 2 个窗口 2:1 与 1:1：行高 (1000-20)/3 = 326.7，宽分别为 653 与 327
    const ratios = [_]f32{ 2.0, 1.0 };
    const boxes = try flexLayout(&ratios, 1000, 400, 10, std.testing.allocator);
    defer std.testing.allocator.free(boxes);
    try std.testing.expectEqual(@as(usize, 2), boxes.len);
    try std.testing.expectEqual(@as(i32, 0), boxes[0].x);
    try std.testing.expectEqual(@as(i32, 653), boxes[0].width);
    try std.testing.expectEqual(@as(i32, 663), boxes[1].x);
    try std.testing.expectEqual(@as(i32, 327), boxes[1].width);
    try std.testing.expectEqual(boxes[0].height, boxes[1].height);
}