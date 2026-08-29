const std = @import("std");
const introspection = @import("introspection.zig");

/// Generates Zig Proxy source code from a D-Bus Node tree.
pub fn generate(writer: *std.Io.Writer, node: introspection.Node, dest: ?[]const u8, path: ?[]const u8) !void {
    try writer.writeAll(
        \\const std = @import("std");
        \\const goose = @import("goose");
        \\const proxy = goose.proxy;
        \\const GStr = goose.core.value.GStr;
        \\const GPath = goose.core.value.GPath;
        \\const GSig = goose.core.value.GSig;
        \\const GUFd = goose.core.value.GUFd;
        \\const GVariant = goose.core.value.GVariant;
        \\
    );

    for (node.interfaces) |iface| {
        // Simple name cleaning (e.g. org.freedesktop.DBus -> DBus)
        var short_name = iface.name;
        if (std.mem.lastIndexOfScalar(u8, iface.name, '.')) |pos| {
            short_name = iface.name[pos + 1 ..];
        }

        try writer.print(
            \\pub const {s}Proxy = struct {{
            \\  inner: proxy.Proxy,
            \\
            \\  pub fn init(conn: *goose.Connection
        , .{short_name});
        if (dest == null) try writer.writeAll(", dest: [:0]const u8");
        if (path == null) try writer.writeAll(", path: [:0]const u8");
        try writer.print(
            \\) {s}Proxy {{
            \\      return .{{ .inner = proxy.Proxy.init(conn
        , .{short_name});

        if (dest) |d| {
            try writer.print(", \"{s}\"", .{d});
        } else {
            try writer.writeAll(", dest");
        }

        if (path) |p| {
            try writer.print(", \"{s}\"", .{p});
        } else {
            try writer.writeAll(", path");
        }

        try writer.print(
            \\, "{s}") }};
            \\}}
            \\
            \\
        , .{iface.name});

        for (iface.methods) |method| {
            try writer.print("   pub fn {s}(self: {s}Proxy", .{ method.name, short_name });
            // Generate In args
            var in_idx: usize = 0;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    try writer.writeAll(", ");
                    if (arg.name.len > 0) {
                        try writer.writeAll(arg.name);
                    } else {
                        try writer.print("arg{d}", .{in_idx});
                        in_idx += 1;
                    }
                    try writer.writeAll(": ");
                    try dbusTypeToZig(writer, arg.type, true);
                }
            }

            // Return type
            var out_sig: ?[]const u8 = null;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "out")) {
                    out_sig = arg.type;
                    break;
                }
            }

            try writer.writeAll(") !");
            if (out_sig) |s| {
                try dbusTypeToZig(writer, s, false);
            } else {
                try writer.writeAll("void");
            }

            try writer.print(
                \\ {{
                \\      var res = try self.inner.call("{s}", .{{
            , .{method.name});

            var call_idx: usize = 0;
            var first = true;
            for (method.args) |arg| {
                if (std.mem.eql(u8, arg.direction, "in")) {
                    if (!first) try writer.writeByte(',');
                    if (arg.name.len > 0) {
                        try writer.print(" {s}", .{arg.name});
                    } else {
                        try writer.print(" arg{d}", .{call_idx});
                    }
                    first = false;
                    call_idx += 1;
                }
            }
            try writer.writeAll("});\n");

            try writer.writeAll("      defer res.deinit();\n");
            if (out_sig) |s| {
                try writer.writeAll("        return res.expectAlloc(");
                try dbusTypeToZig(writer, s, false);
                try writer.writeAll(");\n");
            }
            try writer.writeAll("    }\n\n");
        }

        for (iface.signals) |signal| {
            try writer.print(
                \\    pub fn connect{s}(
                \\        self: {s}Proxy,
                \\        ctx: anytype,
                \\        comptime callback: fn (@TypeOf(ctx), struct{{
            , .{ signal.name, short_name });
            var first = true;
            for (signal.args) |arg| {
                if (!first) try writer.writeByte(',');
                try writer.writeByte(' ');
                try dbusTypeToZig(writer, arg.type, false);
                first = false;
            }

            try writer.writeAll(
                \\}) void,
                \\  ) !void {
                \\      try self.inner.connectSignal(struct{
            );

            first = true;
            for (signal.args) |arg| {
                if (!first) try writer.writeByte(',');
                try writer.writeByte(' ');
                try dbusTypeToZig(writer, arg.type, false);
                first = false;
            }

            try writer.print(
                \\}}, "{s}", ctx, callback);
                \\  }}
                \\
            , .{signal.name});
        }

        try writer.writeAll("};\n\n");
    }
}

fn matchBasicType(sig: []const u8) ?[]const u8 {
    if (sig.len != 1) return null;
    return switch (sig[0]) {
        'y' => "u8",
        'b' => "bool",
        'n' => "i16",
        'q' => "u16",
        'i' => "i32",
        'u' => "u32",
        'x' => "i64",
        't' => "u64",
        'd' => "f64",
        's' => "GStr",
        'o' => "GPath",
        'g' => "GSig",
        'h' => "GUFd",
        'v' => "GVariant",
        else => null,
    };
}

fn nextSingleSig(sig: []const u8) ?[]const u8 {
    if (sig.len == 0) return null;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return sig[0..1],
        'a' => {
            const child = nextSingleSig(sig[1..]) orelse return null;
            return sig[0 .. 1 + child.len];
        },
        '(', '{' => {
            var depth: usize = 0;
            const open_char = sig[0];
            const close_char: u8 = if (open_char == '(') ')' else '}';
            for (sig, 0..) |c, idx| {
                if (c == open_char) depth += 1;
                if (c == close_char) {
                    depth -= 1;
                    if (depth == 0) {
                        return sig[0 .. idx + 1];
                    }
                }
            }
            return null;
        },
        else => return null,
    }
}

fn dbusTypeToZig(writer: *std.Io.Writer, sig: []const u8, is_param: bool) !void {
    if (matchBasicType(sig)) |basic| {
        return writer.writeAll(basic);
    }

    // Dictionaries: a{kv}
    if (sig.len >= 4 and std.mem.startsWith(u8, sig, "a{") and sig[sig.len - 1] == '}') {
        const key_char = sig[2];
        const val_sig = sig[3 .. sig.len - 1];
        if (key_char == 's' or key_char == 'o' or key_char == 'g') {
            try writer.writeAll("std.StringHashMap(");
        } else {
            try writer.print("std.AutoHashMap({s}, ", .{matchBasicType(sig[2..3]) orelse "u32"});
        }

        try dbusTypeToZig(writer, val_sig, false);
        return writer.writeByte(')');
    }

    // Arrays: a... (excluding dictionaries handled above)
    if (std.mem.startsWith(u8, sig, "a")) {
        const child_sig = sig[1..];
        try writer.writeAll("[]const ");
        return dbusTypeToZig(writer, child_sig, false);
    }

    // Structs / Tuples: (...)
    if (sig.len >= 2 and sig[0] == '(' and sig[sig.len - 1] == ')') {
        var inner = sig[1 .. sig.len - 1];
        try writer.writeAll("struct{ ");
        var fst: bool = true;
        while (inner.len > 0) {
            if (!fst) try writer.writeAll(", ");
            const field_sig = nextSingleSig(inner) orelse break;
            try dbusTypeToZig(writer, field_sig, is_param);
            inner = inner[field_sig.len..];
            fst = false;
        }
        if (inner.len > 0) return error.InvalidType;
        try writer.writeAll(" }");
        return;
    }

    return error.InvalidType;
}

fn dbusTypeToZigAlloc(allocator: std.mem.Allocator, sig: []const u8, is_param: bool) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try dbusTypeToZig(&writer.writer, sig, is_param);

    return writer.toOwnedSlice();
}

test "dbusTypeToZig mappings" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("u8", try dbusTypeToZigAlloc(alloc, "y", false));
    try testing.expectEqualStrings("i32", try dbusTypeToZigAlloc(alloc, "i", false));
    try testing.expectEqualStrings("GStr", try dbusTypeToZigAlloc(alloc, "s", false));
    try testing.expectEqualStrings("GPath", try dbusTypeToZigAlloc(alloc, "o", false));
    try testing.expectEqualStrings("GVariant", try dbusTypeToZigAlloc(alloc, "v", false));

    // Arrays
    try testing.expectEqualStrings("[]const GStr", try dbusTypeToZigAlloc(alloc, "as", false));
    try testing.expectEqualStrings("[]const []const u8", try dbusTypeToZigAlloc(alloc, "aay", false));

    // Dictionaries
    try testing.expectEqualStrings("std.StringHashMap(GVariant)", try dbusTypeToZigAlloc(alloc, "a{sv}", false));
    try testing.expectEqualStrings("std.AutoHashMap(u32, u32)", try dbusTypeToZigAlloc(alloc, "a{uu}", false));
    try testing.expectEqualStrings("std.StringHashMap(std.StringHashMap(GVariant))", try dbusTypeToZigAlloc(alloc, "a{sa{sv}}", false));

    // Structs / Tuples
    try testing.expectEqualStrings("struct{ i32, i32 }", try dbusTypeToZigAlloc(alloc, "(ii)", false));
    try testing.expectEqualStrings("struct{ i32, GStr }", try dbusTypeToZigAlloc(alloc, "(is)", false));
    try testing.expectEqualStrings("struct{ GStr, std.StringHashMap(GVariant) }", try dbusTypeToZigAlloc(alloc, "(sa{sv})", false));
    try testing.expectEqualStrings("[]const struct{ i32, GStr }", try dbusTypeToZigAlloc(alloc, "a(is)", false));
    try testing.expectEqualStrings("struct{ i32, struct{ GStr, GStr } }", try dbusTypeToZigAlloc(alloc, "(i(ss))", false));

    // Unrecognized fallbacks
    try testing.expectError(error.InvalidType, dbusTypeToZigAlloc(alloc, "z", true));
    try testing.expectError(error.InvalidType, dbusTypeToZigAlloc(alloc, "z", false));
}
