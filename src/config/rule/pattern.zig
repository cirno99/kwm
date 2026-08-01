const Self = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.pattern);

const mvzr = @import("mvzr");

str: []const u8,
regex: bool = false,
match_null: bool = false,

var regex_cache: ?std.StringHashMap(mvzr.Regex) = null;

pub fn clear_cache() void {
    if (regex_cache) |*cache| {
        cache.deinit();
        regex_cache = null;
    }
}

fn get_regex(str: []const u8) ?mvzr.Regex {
    if (regex_cache == null) {
        regex_cache = std.StringHashMap(mvzr.Regex).init(std.heap.page_allocator);
    }
    const cache = &regex_cache.?;

    if (cache.get(str)) |pattern| return pattern;

    const pattern = mvzr.compile(str) orelse return null;
    cache.put(str, pattern) catch {};
    return pattern;
}

pub fn is_match(self: *const Self, haystack: ?[]const u8) bool {
    if (haystack == null) {
        log.debug("<{*}> matched null", .{ self });
        return self.match_null;
    }

    const matched = blk: {
        if (self.regex) {
            const pattern = get_regex(self.str) orelse return false;
            break :blk pattern.isMatch(haystack.?);
        } else {
            break :blk mem.eql(u8, self.str, haystack.?);
        }
    };

    if (matched) {
        log.debug("<{*}> matched `{s}`", .{ self, haystack.? });
    }

    return matched;
}
