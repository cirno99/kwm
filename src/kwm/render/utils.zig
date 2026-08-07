const std = @import("std");
const mem = std.mem;
const unicode = std.unicode;

const fcft = @import("fcft");
const pixman = @import("pixman");

const utils = @import("../utils.zig");
const Context = @import("../context.zig");

const ctx = Context.get();


pub fn to_utf8(gpa: mem.Allocator, bytes: []const u8) ![]u32 {
    const view = try unicode.Utf8View.init(bytes);

    // A single decode pass over the input: fill a worst-case sized buffer
    // (one u32 per byte) and shrink it to the actual codepoint count instead
    // of scanning the input twice.
    const runes = try gpa.alloc(u32, bytes.len);
    errdefer gpa.free(runes);

    var i: usize = 0;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |rune| : (i += 1) runes[i] = rune;

    return try gpa.realloc(runes, i);
}


pub fn text_width(text: *const fcft.TextRun) u32 {
    var width: u32 = 0;
    for (0..text.count) |i| {
        width += @intCast(text.glyphs[i].advance.x);
    }
    return width;
}

pub fn str_width(font: *fcft.Font, str: []const u8) !u32 {
    const utf8 = try to_utf8(ctx.gpa, str);
    defer ctx.gpa.free(utf8);

    const text = try font.rasterizeTextRunUtf32(utf8, .default);
    defer text.destroy();

    return text_width(text);
}


pub fn color(rgba: u32) pixman.Color {
    const c = utils.rgba(rgba);
    return .{
        .red = @truncate(c.r << 8),
        .green = @truncate(c.g << 8),
        .blue = @truncate(c.b << 8),
        .alpha = @truncate(c.a << 8),
    };
}

test "to_utf8 decodes ascii and multibyte in a single pass" {
    const testing = std.testing;

    const ascii = try to_utf8(testing.allocator, "hello");
    defer testing.allocator.free(ascii);
    try testing.expectEqualSlices(u32, &.{ 'h', 'e', 'l', 'l', 'o' }, ascii);

    const mixed = try to_utf8(testing.allocator, "a中文z\u{1F600}");
    defer testing.allocator.free(mixed);
    try testing.expectEqualSlices(u32, &.{ 'a', 0x4E2D, 0x6587, 'z', 0x1F600 }, mixed);

    const empty = try to_utf8(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}
