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

pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const windows = &ctx.layout_windows;
    try ctx.collect_layout_windows(output);

    if (windows.items.len == 0) return;

    const usable_width = @max(0, output.exclusive_width() - 2 * self.outer_gap);
    const usable_height = @max(0, output.exclusive_height() - 2 * self.outer_gap);

    const window_num: i32 = @intCast(windows.items.len);
    const nmaster = @max(1, @min(window_num, self.nmaster));
    const nstack = window_num - nmaster;
    const master_num: usize = @intCast(nmaster);
    const stack_num: usize = @intCast(nstack);
    const half_gap = @divFloor(self.inner_gap, 2);

    const vertical = switch (self.master_location) {
        .left, .right => true,
        .top, .bottom => false,
    };

    var region = Rect{ .x = 0, .y = 0, .w = usable_width, .h = usable_height };

    // master band, split along the first direction
    if (vertical) {
        const band_w: i32 = if (nstack > 0)
            @intFromFloat(self.mfact * @as(f32, @floatFromInt(usable_width)))
        else
            usable_width;
        const master_h = @divFloor(usable_height, nmaster);
        const master_remain = @mod(usable_height, nmaster);
        const w = if (nstack > 0) band_w - half_gap else band_w;
        const x = switch (self.master_location) {
            .left => 0,
            .right => if (nstack > 0) usable_width - band_w + half_gap else usable_width - band_w,
            else => unreachable,
        };
        var y: i32 = 0;
        for (0..master_num) |m| {
            const h = (master_h + if (m == 0) master_remain else 0) - if (m > 0) self.inner_gap else 0;
            place(windows.items[m], .{ .x = x, .y = y, .w = w, .h = h }, self.outer_gap);
            y += h + if (m + 1 < master_num) self.inner_gap else 0;
        }
        if (nstack > 0) {
            region = switch (self.master_location) {
                .left => .{ .x = band_w + half_gap, .y = 0, .w = usable_width - band_w - half_gap, .h = usable_height },
                .right => .{ .x = 0, .y = 0, .w = usable_width - band_w - half_gap, .h = usable_height },
                else => unreachable,
            };
        }
    } else {
        const band_h: i32 = if (nstack > 0)
            @intFromFloat(self.mfact * @as(f32, @floatFromInt(usable_height)))
        else
            usable_height;
        const master_w = @divFloor(usable_width, nmaster);
        const master_remain = @mod(usable_width, nmaster);
        const h = if (nstack > 0) band_h - half_gap else band_h;
        const y = switch (self.master_location) {
            .top => 0,
            .bottom => if (nstack > 0) usable_height - band_h + half_gap else usable_height - band_h,
            else => unreachable,
        };
        var x: i32 = 0;
        for (0..master_num) |m| {
            const w = (master_w + if (m == 0) master_remain else 0) - if (m > 0) self.inner_gap else 0;
            place(windows.items[m], .{ .x = x, .y = y, .w = w, .h = h }, self.outer_gap);
            x += w + if (m + 1 < master_num) self.inner_gap else 0;
        }
        if (nstack > 0) {
            region = switch (self.master_location) {
                .top => .{ .x = 0, .y = band_h + half_gap, .w = usable_width, .h = usable_height - band_h - half_gap },
                .bottom => .{ .x = 0, .y = 0, .w = usable_width, .h = usable_height - band_h - half_gap },
                else => unreachable,
            };
        }
    }

    // spiral the remaining windows, alternating the split direction
    var next_vertical = !vertical;
    for (0..stack_num) |s| {
        const window = windows.items[master_num + s];
        if (s == stack_num - 1) {
            place(window, region, self.outer_gap);
            break;
        }
        if (next_vertical) {
            const slice = @divFloor(region.w, 2);
            place(window, .{ .x = region.x, .y = region.y, .w = slice - half_gap, .h = region.h }, self.outer_gap);
            region.x += slice + half_gap;
            region.w = @max(0, region.w - slice - half_gap);
        } else {
            const slice = @divFloor(region.h, 2);
            place(window, .{ .x = region.x, .y = region.y, .w = region.w, .h = slice - half_gap }, self.outer_gap);
            region.y += slice + half_gap;
            region.h = @max(0, region.h - slice - half_gap);
        }
        next_vertical = !next_vertical;
    }
}
