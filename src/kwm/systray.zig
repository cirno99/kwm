const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const log = std.log.scoped(.systray);

const goose = @import("goose");
const core = goose.core;
const GStr = core.value.GStr;
const GVariant = core.value.GVariant;
const Proxy = goose.proxy.Proxy;
const BodyEncoder = goose.message.BodyEncoder;
const BodyDecoder = goose.message.BodyDecoder;
const Message = core.Message;
const MessageHeader = core.MessageHeader;
const HeaderField = core.HeaderField;

const flate = std.compress.flate;

const pixman = @import("pixman");
const posix = @import("posix");
const render_utils = @import("render/utils.zig");
const Context = @import("context.zig");

const ctx = Context.get();

// ---------------------------------------------------------------------------
// Shared snapshot (owned by the dbus thread, consumed by the main thread).
// ---------------------------------------------------------------------------

pub const Snapshot = struct {
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    /// Composited tray strip at the target icon height, or null when empty.
    strip: ?*pixman.Image,
    /// Physical width of the strip.
    width: i32,
    /// Physical height of the strip (== the icon target height).
    height: i32,

    pub fn ref(self: *Snapshot) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *Snapshot) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            if (self.strip) |image| _ = image.unref();
            ctx.gpa.destroy(self);
        }
    }
};

// ---------------------------------------------------------------------------
// Item registry (owned by the dbus thread).
// ---------------------------------------------------------------------------

const Item = struct {
    dest: [:0]u8,
    path: [:0]u8,
    owner: [:0]u8,
    title: ?[:0]u8 = null,
    icon: ?*pixman.Image = null,
    /// Owned by the items list; extra references are held while an item is
    /// being refetched, because the synchronous GetAll call dispatches nested
    /// signals that may remove the same item reentrantly.
    refs: u32 = 1,
    /// Set while a GetAll refetch is in flight, so nested signals for this
    /// item coalesce into the in-flight refetch instead of racing a second
    /// synchronous call (which fails and would drop a live item).
    busy: bool = false,
};

fn item_ref(it: *Item) void {
    it.refs +%= 1;
}

fn item_unref(it: *Item) void {
    std.debug.assert(it.refs > 0);
    it.refs -= 1;
    if (it.refs == 0) {
        log.debug("systray item removed: {s}", .{it.dest});
        if (it.icon) |icon| _ = icon.unref();
        if (it.title) |t| ctx.gpa.free(t);
        ctx.gpa.free(it.owner);
        ctx.gpa.free(it.path);
        ctx.gpa.free(it.dest);
        ctx.gpa.destroy(it);
    }
}

var items: std.ArrayList(*Item) = .empty;

var target_height: u32 = 0;

// When true, kwm itself owns `org.kde.StatusNotifierWatcher` on the session
// bus, so no external tray host / watcher is required.
var is_watcher: bool = false;
var registered_hosts: std.ArrayList([:0]u8) = .empty;

const SignalCtx = struct { conn: *goose.Connection };
var sig_ctx: SignalCtx = undefined;

// ---------------------------------------------------------------------------
// Main-thread accessible state.
// ---------------------------------------------------------------------------

pub var wake_fd: posix.fd_t = -1;
var request_fd: posix.fd_t = -1;
/// Latest icon height requested by the bar (main thread); read by the dbus
/// thread on `request_fd` wakeup. No queue is needed: the height is monotonic
/// state, and the eventfd only exists to nudge the poll loop.
var posted_height: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

var snapshot_mutex: std.Io.Mutex = .init;
var current_snapshot: ?*Snapshot = null;

var running = std.atomic.Value(bool).init(false);

// Icon theme base directories, cached on the main thread at init so the dbus
// thread never touches `ctx.env` (which the main thread may rebuild on config
// reload).
var icon_bases: [8][]const u8 = undefined;
var icon_bases_len: usize = 0;

// ---------------------------------------------------------------------------
// Public API (main thread).
// ---------------------------------------------------------------------------

pub inline fn is_running() bool {
    return wake_fd >= 0;
}

/// Returns a reference-counted snapshot of the current tray, or null when the
/// tray is empty. The caller must call `unref` on the returned snapshot.
pub fn snapshot() ?*Snapshot {
    if (wake_fd < 0) return null;
    snapshot_mutex.lockUncancelable(ctx.io);
    defer snapshot_mutex.unlock(ctx.io);
    const snap = current_snapshot orelse return null;
    snap.ref();
    return snap;
}

pub fn update_bar_size(height: u32) void {
    if (height == 0 or height == posted_height.load(.monotonic)) return;
    posted_height.store(height, .monotonic);
    if (request_fd >= 0) posix.eventfd_notify(request_fd);
}

pub fn init() void {
    if (!build_options.bar_enabled) return;
    if (!ctx.cfg.bar.systray.enabled) return;
    if (wake_fd >= 0) return; // already initialized

    wake_fd = posix.eventfd(0, posix.EFD.CLOEXEC) catch |err| {
        log.warn("create systray wake fd failed: {}", .{err});
        wake_fd = -1;
        return;
    };
    request_fd = posix.eventfd(0, posix.EFD.CLOEXEC) catch |err| {
        log.warn("create systray request fd failed: {}", .{err});
        posix.close(wake_fd);
        wake_fd = -1;
        request_fd = -1;
        return;
    };
    posted_height.store(0, .monotonic);
    running.store(true, .release);

    build_icon_bases();

    const thread = std.Thread.spawn(.{}, dbus_thread, .{}) catch |err| {
        log.err("spawn systray thread failed: {}", .{err});
        posix.close(wake_fd);
        posix.close(request_fd);
        wake_fd = -1;
        request_fd = -1;
        return;
    };
    thread.detach();
}

pub fn deinit() void {
    running.store(false, .release);
}

// ---------------------------------------------------------------------------
// D-Bus thread.
// ---------------------------------------------------------------------------

fn dbus_thread() void {
    log.info("systray thread started", .{});

    while (running.load(.acquire)) {
        var conn = goose.Connection.init(ctx.gpa, .Session, ctx.io, &ctx.env) catch |err| {
            log.warn("systray connect to session bus failed: {}", .{err});
            reset_state();
            retry_delay();
            continue;
        };
        const reconnect = serve_bus(&conn);
        conn.close();
        if (!reconnect) break;
        reset_state();
        retry_delay();
    }

    log.info("systray thread stopped", .{});
}

/// Runs one session-bus connection until it dies or the thread is asked to
/// stop. Returns `true` when the connection was lost and should be retried,
/// `false` when deinit was requested and the thread should exit.
fn serve_bus(conn: *goose.Connection) bool {
    sig_ctx = .{ .conn = conn };

    is_watcher = claim_watcher_name(conn);
    if (is_watcher) register_self_as_host(conn);
    setup_subs(conn);
    publish();

    var poll_fds = [_]posix.pollfd{
        .{ .fd = conn.__inner_sock.socket.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = request_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    while (running.load(.acquire)) {
        const n = posix.poll(&poll_fds, -1) catch |err| {
            log.warn("systray poll failed: {}", .{err});
            continue;
        };
        if (n == 0) continue;

        if (poll_fds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            drain_requests();
        }

        if (poll_fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            const msg = conn.waitMessage() catch |err| {
                log.warn("systray waitMessage failed: {}", .{err});
                if (err == error.EndOfStream or err == error.ConnectionResetByPeer) return true;
                continue;
            };
            if (msg.header.message_type == .Signal) {
                dispatch_signal(msg);
            } else if (is_watcher and msg.header.message_type == .MethodCall) {
                handle_watcher_call(conn, msg);
            }
            conn.freeMessage(@constCast(&msg));
        }
    }
    return false;
}

fn retry_delay() void {
    if (!running.load(.acquire)) return;
    const delay = posix.system.timespec{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
    _ = posix.system.nanosleep(&delay, null);
}

/// Drops all in-memory tray state so a fresh connection re-enumerates from
/// scratch. Called on the dbus thread between connection attempts.
fn reset_state() void {
    for (items.items) |it| item_unref(it);
    items.clearRetainingCapacity();

    for (registered_hosts.items) |h| ctx.gpa.free(h);
    registered_hosts.clearRetainingCapacity();
    is_watcher = false;

    snapshot_mutex.lockUncancelable(ctx.io);
    defer snapshot_mutex.unlock(ctx.io);
    if (current_snapshot) |old| {
        old.unref();
        current_snapshot = null;
    }
}

fn setup_subs(c: *goose.Connection) void {
    // Subscribe to the watcher's registration signals and the item property
    // signals. Handlers are NOT registered with goose: goose's `waitMessage`
    // would otherwise dispatch matching signals in a loop, blocking on the next
    // D-Bus message while the request eventfd goes unserviced. Instead signals
    // are dispatched manually in `dbus_thread` (see dispatch_signal) so the
    // poll loop returns to check the request queue after every message.
    _ = c.addMatch("type='signal',interface='org.kde.StatusNotifierWatcher',member='StatusNotifierItemRegistered'") catch {};
    _ = c.addMatch("type='signal',interface='org.kde.StatusNotifierWatcher',member='StatusNotifierItemUnregistered'") catch {};
    _ = c.addMatch("type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'") catch {};
    _ = c.addMatch("type='signal',interface='org.kde.StatusNotifierItem'") catch {};

    if (is_watcher) return;

    register_host(c);
    enumerate(c);
}

fn register_host(c: *goose.Connection) void {
    const watcher = Proxy.init(c, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher");
    var res = watcher.call("RegisterStatusNotifierHost", .{GStr.new("")}) catch |err| {
        log.debug("RegisterStatusNotifierHost failed: {}", .{err});
        return;
    };
    res.deinit();
}

fn enumerate(c: *goose.Connection) void {
    const watcher = Proxy.init(c, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher");
    var res = watcher.rawCall("org.freedesktop.DBus.Properties", "GetAll", .{GStr.new("org.kde.StatusNotifierWatcher")}) catch return;
    defer res.deinit();
    if (res.msg.isError()) return;

    var dec = res.reader();
    const props = dec.decodeAlloc(std.StringHashMap(GVariant)) catch return;
    const entry = props.get("RegisteredStatusNotifierItems") orelse return;
    const inner = if (entry == .variant) entry.variant else return;
    if (inner.* == .array) {
        for (inner.array) |*e| {
            if (e.* == .string) add_item(c, e.string.s);
        }
    }
}

/// Dispatches a D-Bus signal to the matching systray handler. Signals are
/// handled here (instead of via goose's `waitMessage` handler dispatch) so the
/// dbus thread's poll loop can return to servicing the request eventfd after
/// every message, preventing resize requests from being starved while the
/// connection is otherwise idle.
fn dispatch_signal(msg: Message) void {
    var iface: ?[]const u8 = null;
    var member: ?[]const u8 = null;
    for (msg.header.header_fields) |f| {
        switch (f.value) {
            .Interface => |s| iface = s,
            .Member => |s| member = s,
            else => {},
        }
    }
    const i = iface orelse return;
    const m = member orelse return;

    if (mem.eql(u8, i, "org.kde.StatusNotifierWatcher")) {
        if (mem.eql(u8, m, "StatusNotifierItemRegistered")) {
            var dec = BodyDecoder.fromMessage(ctx.gpa, msg);
            const svc = dec.decode(@Tuple(&[_]type{GStr})) catch return;
            on_item_registered(&sig_ctx, svc);
        } else if (mem.eql(u8, m, "StatusNotifierItemUnregistered")) {
            var dec = BodyDecoder.fromMessage(ctx.gpa, msg);
            const svc = dec.decode(@Tuple(&[_]type{GStr})) catch return;
            on_item_unregistered(&sig_ctx, svc);
        }
    } else if (mem.eql(u8, i, "org.freedesktop.DBus") and mem.eql(u8, m, "NameOwnerChanged")) {
        var dec = BodyDecoder.fromMessage(ctx.gpa, msg);
        const args = dec.decode(@Tuple(&[_]type{ GStr, GStr, GStr })) catch return;
        on_name_owner_changed(&sig_ctx, args);
    } else if (mem.eql(u8, i, "org.kde.StatusNotifierItem")) {
        on_item_signal(&sig_ctx, msg);
    }
}

fn on_name_owner_changed(sctx: *SignalCtx, args: @Tuple(&[_]type{ GStr, GStr, GStr })) void {
    const name, const old, const new = args;
    _ = old;

    if (is_watcher) {
        // kwm owns the watcher name itself: detect items that went away.
        if (new.s.len == 0) {
            for (items.items) |it| {
                if (mem.eql(u8, it.owner, name.s) or mem.eql(u8, it.dest, name.s)) {
                    const service = ctx.gpa.dupeZ(u8, it.dest) catch return;
                    defer ctx.gpa.free(service);
                    remove_item_by_service(name.s);
                    emit_watcher_signal(sctx.conn, "StatusNotifierItemUnregistered", service);
                    publish();
                    return;
                }
            }
        }
        return;
    }

    if (mem.eql(u8, name.s, "org.kde.StatusNotifierWatcher") and new.s.len > 0) {
        log.debug("StatusNotifierWatcher appeared, re-registering", .{});
        register_host(sctx.conn);
        enumerate(sctx.conn);
        publish();
    }
}

fn on_item_registered(sctx: *SignalCtx, args: @Tuple(&[_]type{GStr})) void {
    add_item(sctx.conn, args[0].s);
}

fn on_item_unregistered(sctx: *SignalCtx, args: @Tuple(&[_]type{GStr})) void {
    _ = sctx;
    remove_item_by_service(args[0].s);
    publish();
}

fn on_item_signal(sctx: *SignalCtx, msg: Message) void {
    const sender = msg_sender(msg) orelse return;
    for (items.items) |it| {
        if (mem.eql(u8, it.owner, sender)) {
            refetch_item(sctx.conn, it);
            return;
        }
    }
}

fn msg_sender(msg: Message) ?[:0]const u8 {
    for (msg.header.header_fields) |f| {
        if (f.code == .Sender) return f.value.Sender;
    }
    return null;
}

// ---------------------------------------------------------------------------
// StatusNotifierWatcher role.
//
// When kwm owns the `org.kde.StatusNotifierWatcher` well-known name it serves
// the registry itself, so no external tray host or watcher process is needed:
// SNI apps register directly with kwm and kwm displays their icons.
// ---------------------------------------------------------------------------

fn claim_watcher_name(c: *goose.Connection) bool {
    const bus = Proxy.init(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
    var res = bus.call("RequestName", .{ GStr.new("org.kde.StatusNotifierWatcher"), @as(u32, 4) }) catch {
        log.debug("claim watcher name failed", .{});
        return false;
    };
    defer res.deinit();
    const result: u32 = res.expect(u32) catch return false;
    // 1 = PRIMARY_OWNER, 4 = ALWAYS_OWNER
    if (result == 1 or result == 4) {
        log.info("kwm is the StatusNotifierWatcher", .{});
        return true;
    }
    log.info("StatusNotifierWatcher owned by another process (RequestName result {})", .{result});
    return false;
}

/// kwm both owns the watcher and renders the tray, so it is itself a status
/// notifier host. Some clients (e.g. Electron's tray) check the watcher's
/// `IsStatusNotifierHostRegistered` property and fall back to the X11 XEmbed
/// tray when it is false, so register our own bus name as a host.
fn register_self_as_host(c: *goose.Connection) void {
    const bus = Proxy.init(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
    var res = bus.call("GetNameOwner", .{GStr.new("org.kde.StatusNotifierWatcher")}) catch return;
    defer res.deinit();
    const owner = res.expectAlloc(GStr) catch return;
    for (registered_hosts.items) |h| {
        if (mem.eql(u8, h, owner.s)) return;
    }
    const owned = ctx.gpa.dupeZ(u8, owner.s) catch return;
    registered_hosts.append(ctx.gpa, owned) catch {
        ctx.gpa.free(owned);
    };
    log.debug("kwm registered itself as a status notifier host ({s})", .{owned});
}

fn handle_watcher_call(c: *goose.Connection, msg: Message) void {
    var iface: ?[]const u8 = null;
    var member: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    for (msg.header.header_fields) |f| {
        switch (f.value) {
            .Interface => |s| iface = s,
            .Member => |s| member = s,
            .Path => |s| path = s,
            else => {},
        }
    }

    if (path == null or !mem.eql(u8, path.?, "/StatusNotifierWatcher")) {
        send_error(c, msg, "org.freedesktop.DBus.Error.UnknownObject", "unknown object path");
        return;
    }

    const i = iface orelse "";
    const m = member orelse "";

    if (mem.eql(u8, i, "org.kde.StatusNotifierWatcher")) {
        if (mem.eql(u8, m, "RegisterStatusNotifierItem")) {
            const service = method_arg_string(msg) orelse {
                send_error(c, msg, "org.freedesktop.DBus.Error.InvalidArgs", "expected a string argument");
                return;
            };
            handle_watcher_register_item(c, msg, service);
            return;
        }
        if (mem.eql(u8, m, "RegisterStatusNotifierHost")) {
            handle_watcher_register_host(c, msg);
            return;
        }
    } else if (mem.eql(u8, i, "org.freedesktop.DBus.Properties")) {
        if (mem.eql(u8, m, "Get")) {
            var dec = BodyDecoder.fromMessage(ctx.gpa, msg);
            _ = dec.decode(GStr) catch {
                send_error(c, msg, "org.freedesktop.DBus.Error.InvalidArgs", "expected two string arguments");
                return;
            };
            const name = dec.decode(GStr) catch {
                send_error(c, msg, "org.freedesktop.DBus.Error.InvalidArgs", "expected two string arguments");
                return;
            };
            reply_property(c, msg, name.s);
            return;
        }
        if (mem.eql(u8, m, "GetAll")) {
            reply_properties(c, msg);
            return;
        }
        if (mem.eql(u8, m, "Set")) {
            send_error(c, msg, "org.freedesktop.DBus.Error.InvalidArgs", "properties are read-only");
            return;
        }
    } else if (mem.eql(u8, i, "org.freedesktop.DBus.Introspectable") and mem.eql(u8, m, "Introspect")) {
        reply_introspect(c, msg);
        return;
    }

    send_error(c, msg, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
}

fn method_arg_string(msg: Message) ?[]const u8 {
    var dec = BodyDecoder.fromMessage(ctx.gpa, msg);
    const arg = dec.decode(GStr) catch return null;
    return arg.s;
}

fn handle_watcher_register_item(c: *goose.Connection, msg: Message, service: []const u8) void {
    // Reply promptly so the registering app is not kept waiting.
    reply_void(c, msg);
    log.debug("watcher: item registered: {s}", .{service});

    // Ayatana-style registration passes a bare object path; the object then
    // lives on the caller's own connection, so resolve the destination from
    // the message sender.
    if (mem.startsWith(u8, service, "/")) {
        if (msg_sender(msg)) |sender| {
            const combined = std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ sender, service }) catch return;
            defer ctx.gpa.free(combined);
            add_item(c, combined);
            emit_watcher_signal(c, "StatusNotifierItemRegistered", service);
        }
        return;
    }

    add_item(c, service);
    emit_watcher_signal(c, "StatusNotifierItemRegistered", service);
}

fn handle_watcher_register_host(c: *goose.Connection, msg: Message) void {
    const host = method_arg_string(msg) orelse "";
    reply_void(c, msg);

    if (host.len > 0) {
        for (registered_hosts.items) |h| {
            if (mem.eql(u8, h, host)) return;
        }
        const owned = ctx.gpa.dupeZ(u8, host) catch return;
        registered_hosts.append(ctx.gpa, owned) catch {
            ctx.gpa.free(owned);
        };
    }
    log.debug("watcher: host registered: {s}", .{host});
}

fn reply_property(c: *goose.Connection, msg: Message, name: []const u8) void {
    if (mem.eql(u8, name, "RegisteredStatusNotifierItems")) {
        const arr = make_service_array() catch return;
        defer ctx.gpa.free(arr);
        reply_variant(c, msg, .{ .array = arr });
        return;
    }
    if (mem.eql(u8, name, "IsStatusNotifierHostRegistered")) {
        reply_variant(c, msg, .{ .boolean = registered_hosts.items.len > 0 });
        return;
    }
    if (mem.eql(u8, name, "ProtocolVersion")) {
        reply_variant(c, msg, .{ .int32 = 0 });
        return;
    }
    if (mem.eql(u8, name, "Hosts")) {
        const arr = make_host_array() catch return;
        defer ctx.gpa.free(arr);
        reply_variant(c, msg, .{ .array = arr });
        return;
    }
    send_error(c, msg, "org.freedesktop.DBus.Error.InvalidArgs", "no such property");
}

fn reply_properties(c: *goose.Connection, msg: Message) void {
    const items_arr = make_service_array() catch return;
    defer ctx.gpa.free(items_arr);
    const hosts_arr = make_host_array() catch return;
    defer ctx.gpa.free(hosts_arr);

    var map = std.StringHashMap(GVariant).init(ctx.gpa);
    defer map.deinit();
    map.put("RegisteredStatusNotifierItems", .{ .array = items_arr }) catch return;
    map.put("IsStatusNotifierHostRegistered", .{ .boolean = registered_hosts.items.len > 0 }) catch return;
    map.put("ProtocolVersion", .{ .int32 = 0 }) catch return;
    map.put("Hosts", .{ .array = hosts_arr }) catch return;

    var enc = BodyEncoder.encode(ctx.gpa, map) catch return;
    defer enc.deinit();
    c.sendReply(msg, enc) catch {};
}

fn reply_introspect(c: *goose.Connection, msg: Message) void {
    const xml =
        \\<node>
        \\  <interface name="org.kde.StatusNotifierWatcher">
        \\    <method name="RegisterStatusNotifierHost"><arg direction="in" type="s"/></method>
        \\    <method name="RegisterStatusNotifierItem"><arg direction="in" type="s"/></method>
        \\    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
        \\    <signal name="StatusNotifierItemUnregistered"><arg type="s"/></signal>
        \\    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
        \\    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
        \\    <property name="ProtocolVersion" type="i" access="read"/>
        \\    <property name="Hosts" type="as" access="read"/>
        \\  </interface>
        \\  <interface name="org.freedesktop.DBus.Properties">
        \\    <method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
        \\    <method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
        \\    <method name="Set"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="v"/></method>
        \\  </interface>
        \\  <interface name="org.freedesktop.DBus.Introspectable">
        \\    <method name="Introspect"><arg direction="out" type="s"/></method>
        \\  </interface>
        \\</node>
    ;
    const xml_z = ctx.gpa.dupeZ(u8, xml) catch return;
    defer ctx.gpa.free(xml_z);
    var enc = BodyEncoder.encode(ctx.gpa, GStr.new(xml_z)) catch return;
    defer enc.deinit();
    c.sendReply(msg, enc) catch {};
}

fn make_service_array() ![]GVariant {
    const arr = try ctx.gpa.alloc(GVariant, items.items.len);
    for (items.items, 0..) |it, i| arr[i] = .{ .string = .{ .s = it.dest } };
    return arr;
}

fn make_host_array() ![]GVariant {
    const arr = try ctx.gpa.alloc(GVariant, registered_hosts.items.len);
    for (registered_hosts.items, 0..) |h, i| arr[i] = .{ .string = .{ .s = h } };
    return arr;
}

fn reply_void(c: *goose.Connection, msg: Message) void {
    var enc = BodyEncoder.encode(ctx.gpa, .{}) catch return;
    defer enc.deinit();
    c.sendReply(msg, enc) catch {};
}

fn reply_variant(c: *goose.Connection, msg: Message, value: GVariant) void {
    var enc = BodyEncoder.encode(ctx.gpa, value) catch return;
    defer enc.deinit();
    c.sendReply(msg, enc) catch {};
}

fn send_error(c: *goose.Connection, msg: Message, error_name: []const u8, text: []const u8) void {
    const en = ctx.gpa.dupeZ(u8, error_name) catch return;
    defer ctx.gpa.free(en);
    const et = ctx.gpa.dupeZ(u8, text) catch return;
    defer ctx.gpa.free(et);
    c.sendError(msg, en, et) catch {};
}

fn emit_watcher_signal(c: *goose.Connection, member: []const u8, service: []const u8) void {
    const service_z = ctx.gpa.dupeZ(u8, service) catch return;
    defer ctx.gpa.free(service_z);
    var enc = BodyEncoder.encode(ctx.gpa, .{GStr.new(service_z)}) catch return;
    defer enc.deinit();
    const member_c = ctx.gpa.dupeZ(u8, member) catch return;
    defer ctx.gpa.free(member_c);

    var fields = std.ArrayList(HeaderField).empty;
    defer fields.deinit(ctx.gpa);
    fields.append(ctx.gpa, .{ .code = .Path, .value = .{ .Path = "/StatusNotifierWatcher" } }) catch return;
    fields.append(ctx.gpa, .{ .code = .Interface, .value = .{ .Interface = "org.kde.StatusNotifierWatcher" } }) catch return;
    fields.append(ctx.gpa, .{ .code = .Member, .value = .{ .Member = member_c } }) catch return;
    fields.append(ctx.gpa, .{ .code = .Signature, .value = .{ .Signature = enc.signature() } }) catch return;

    fire_serial +%= 1;
    const header = MessageHeader{
        .message_type = .Signal,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(enc.body().len),
        .serial = fire_serial,
        .header_fields = fields.items,
    };
    c.sendMessage(Message.new(header, enc.body())) catch {};
}

fn drain_requests() void {
    _ = posix.eventfd_reset(request_fd);

    const height = posted_height.load(.monotonic);
    if (height != target_height) {
        target_height = height;
        log.debug("target icon height set to {}", .{target_height});
        publish();
    }
}

// ---------------------------------------------------------------------------
// Item management (dbus thread).
// ---------------------------------------------------------------------------

fn add_item(c: *goose.Connection, service: []const u8) void {
    // The service string may be either a bare bus name or a "busname/path"
    // pair (used by some clients registering with the watcher).
    const slash = mem.indexOfScalar(u8, service, '/');
    const dest = if (slash) |s| service[0..s] else service;
    const explicit_path = if (slash) |s| service[s..] else null;

    // Ayatana-style registrations pass a bare object path that lives on the
    // caller's own connection; without the caller's bus name there is nothing
    // to address. Making a method call with an empty destination is a protocol
    // violation that makes the daemon drop the whole connection, so skip.
    if (dest.len == 0) {
        log.debug("systray: item registered without a bus name ({s})", .{service});
        return;
    }

    for (items.items) |it| {
        if (mem.eql(u8, it.dest, dest)) return; // already present
    }

    const service_z = ctx.gpa.dupeZ(u8, dest) catch return;
    defer ctx.gpa.free(service_z);

    if (explicit_path) |path| {
        const path_z = ctx.gpa.dupeZ(u8, path) catch return;
        defer ctx.gpa.free(path_z);
        if (try_fetch_item(c, service_z, path_z)) return;
    }

    const paths = [_][:0]const u8{
        "/StatusNotifierItem",
        "/org/kde/StatusNotifierItem",
        "/org/freedesktop/StatusNotifierItem",
    };
    for (paths) |path| {
        if (try_fetch_item(c, service_z, path)) return;
    }
}

fn try_fetch_item(c: *goose.Connection, service_z: [:0]const u8, path: [:0]const u8) bool {
    const proxy = Proxy.init(c, service_z, path, "org.kde.StatusNotifierItem");
    var res = proxy.rawCall("org.freedesktop.DBus.Properties", "GetAll", .{GStr.new("org.kde.StatusNotifierItem")}) catch return false;
    defer res.deinit();
    if (res.msg.isError()) return false;

    var dec = res.reader();
    const props = dec.decodeAlloc(std.StringHashMap(GVariant)) catch return false;

    const item = ctx.gpa.create(Item) catch return false;
    item.* = .{
        .dest = ctx.gpa.dupeZ(u8, service_z) catch {
            ctx.gpa.destroy(item);
            return false;
        },
        .path = ctx.gpa.dupeZ(u8, path) catch {
            ctx.gpa.free(item.dest);
            ctx.gpa.destroy(item);
            return false;
        },
        .owner = get_owner(c, service_z) orelse {
            ctx.gpa.free(item.dest);
            ctx.gpa.free(item.path);
            ctx.gpa.destroy(item);
            return false;
        },
    };

    update_item(item, &props);
    items.append(ctx.gpa, item) catch {
        item_unref(item);
        return false;
    };

    log.debug("systray item registered: {s}{s} ({s})", .{ item.dest, item.path, item.title orelse "" });
    publish();
    return true;
}

fn refetch_item(c: *goose.Connection, it: *Item) void {
    // Skip reentrant refetches: the GetAll call below synchronously dispatches
    // incoming signals, and a nested refetch of this same item would start a
    // second synchronous call on the same connection, which fails and would
    // spuriously drop a live item. Coalesce into the in-flight refetch.
    if (it.busy) return;
    it.busy = true;
    defer it.busy = false;

    // Keep the item alive across the synchronous call: nested signal handling
    // may still remove this very item, and we must not touch a dangling item.
    item_ref(it);
    defer item_unref(it);

    const proxy = Proxy.init(c, it.dest, it.path, "org.kde.StatusNotifierItem");
    var res = proxy.rawCall("org.freedesktop.DBus.Properties", "GetAll", .{GStr.new("org.kde.StatusNotifierItem")}) catch {
        remove_item(it);
        return;
    };
    defer res.deinit();
    if (res.msg.isError()) {
        remove_item(it);
        return;
    }
    var dec = res.reader();
    const props = dec.decodeAlloc(std.StringHashMap(GVariant)) catch {
        remove_item(it);
        return;
    };
    update_item(it, &props);
    publish();
}

fn update_item(it: *Item, props: *const std.StringHashMap(GVariant)) void {
    if (get_str(props, "Title")) |title| {
        const owned = ctx.gpa.dupeZ(u8, title) catch null;
        if (owned) |o| {
            if (it.title) |t| ctx.gpa.free(t);
            it.title = o;
        }
    }

    const new_icon = load_item_icon(props);
    if (it.icon) |old| _ = old.unref();
    it.icon = new_icon;
}

fn remove_item(it: *Item) void {
    for (items.items, 0..) |candidate, i| {
        if (candidate == it) {
            _ = items.orderedRemove(i);
            item_unref(it);
            return;
        }
    }
}

fn remove_item_by_service(service: []const u8) void {
    var i: usize = 0;
    while (i < items.items.len) {
        const it = items.items[i];
        if (mem.eql(u8, it.dest, service) or mem.eql(u8, it.owner, service)) {
            _ = items.orderedRemove(i);
            item_unref(it);
            continue;
        }
        i += 1;
    }
}

fn get_owner(c: *goose.Connection, name: [:0]const u8) ?[:0]u8 {
    if (mem.startsWith(u8, name, ":")) return ctx.gpa.dupeZ(u8, name) catch null;

    const bus = Proxy.init(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");
    var res = bus.call("GetNameOwner", .{GStr.new(name)}) catch return null;
    defer res.deinit();
    const owner = res.expectAlloc(GStr) catch return null;
    return ctx.gpa.dupeZ(u8, owner.s) catch null;
}

// ---------------------------------------------------------------------------
// Property helpers.
// ---------------------------------------------------------------------------

fn get_variant(props: *const std.StringHashMap(GVariant), key: []const u8) ?*const GVariant {
    const entry = props.getPtr(key) orelse return null;
    // `decodeAlloc` on a `a{sv}` yields raw values; only nested variants are
    // `.variant`-wrapped, so unwrap those when present.
    if (entry.* == .variant) return entry.variant;
    return entry;
}

fn get_str(props: *const std.StringHashMap(GVariant), key: []const u8) ?[]const u8 {
    const v = get_variant(props, key) orelse return null;
    if (v.* != .string) return null;
    return v.string.s;
}

fn load_item_icon(props: *const std.StringHashMap(GVariant)) ?*pixman.Image {
    const icon_pix = get_variant(props, "IconPixmap");
    const icon_name = get_str(props, "IconName");
    const att_pix = get_variant(props, "AttentionIconPixmap");
    const att_name = get_str(props, "AttentionIconName");

    const status = get_str(props, "Status") orelse "";
    const attention = mem.eql(u8, status, "NeedsAttention");

    if (attention) {
        if (att_pix) |v| {
            if (icon_from_icon_pixmaps(v)) |img| return img;
        }
        if (att_name) |n| {
            if (n.len > 0) {
                if (icon_from_theme(n)) |img| return img;
            }
        }
    }

    if (icon_pix) |v| {
        if (icon_from_icon_pixmaps(v)) |img| return img;
    }
    if (icon_name) |n| {
        if (n.len > 0) {
            if (icon_from_theme(n)) |img| return img;
        }
    }

    return null;
}

// ---------------------------------------------------------------------------
// Icon loading (dbus thread).
// ---------------------------------------------------------------------------

const PixelBuf = struct { bytes: []u8 };

fn destroy_pixels(image: *pixman.Image, data: ?*anyopaque) callconv(.c) void {
    _ = image;
    if (data) |d| {
        const buf: *PixelBuf = @ptrCast(@alignCast(d));
        ctx.gpa.free(buf.bytes);
        ctx.gpa.destroy(buf);
    }
}

/// Creates an owned pixman image from ARGB32 pixel data (native endian).
fn image_from_argb32(bytes: []const u8, w: i32, h: i32) ?*pixman.Image {
    const n: usize = @intCast(@as(i64, w) * h * 4);
    if (bytes.len < n) return null;

    const owned = ctx.gpa.alloc(u8, n) catch return null;
    @memcpy(owned[0..n], bytes[0..n]);

    const buf = ctx.gpa.create(PixelBuf) catch {
        ctx.gpa.free(owned);
        return null;
    };
    buf.* = .{ .bytes = owned };

    const image = pixman.Image.createBitsNoClear(.a8r8g8b8, w, h, @ptrCast(@alignCast(owned.ptr)), w * 4) orelse {
        ctx.gpa.destroy(buf);
        return null;
    };
    image.setDestroyFunction(destroy_pixels, buf);
    return image;
}

/// Picks the largest pixmap from an `a(iiay)` variant and imports it.
fn icon_from_icon_pixmaps(v: *const GVariant) ?*pixman.Image {
    if (v.* != .array) return null;
    const entries = v.array;

    var best_w: i32 = 0;
    var best_h: i32 = 0;
    var best_arr: []const GVariant = &.{};
    var best_area: i64 = -1;
    for (entries) |*e| {
        if (e.* != .tuple) continue;
        const t = e.tuple;
        if (t.len < 3) continue;
        if (t[0] != .int32 or t[1] != .int32 or t[2] != .array) continue;
        const w = t[0].int32;
        const h = t[1].int32;
        if (w <= 0 or h <= 0) continue;
        const area = @as(i64, w) * h;
        if (area > best_area) {
            best_area = area;
            best_w = w;
            best_h = h;
            best_arr = t[2].array;
        }
    }
    if (best_area <= 0) return null;

    const n: usize = @intCast(@as(i64, best_w) * best_h * 4);
    const bytes = ctx.gpa.alloc(u8, n) catch return null;
    defer ctx.gpa.free(bytes);

    var i: usize = 0;
    for (best_arr) |*pix| {
        if (i >= n) break;
        if (pix.* != .byte) break;
        bytes[i] = pix.byte;
        i += 1;
    }
    if (i < n) return null;

    // The SNI `IconPixmap` data is ARGB32 with the alpha channel first
    // (A, R, G, B per pixel), while pixman's `a8r8g8b8` expects the native
    // little-endian byte order (B, G, R, A in memory). Swap each pixel so the
    // icon is not rendered with inverted colors.
    const endian = @import("builtin").cpu.arch.endian();
    if (endian == .little) {
        var j: usize = 0;
        while (j < n) : (j += 4) {
            const a = bytes[j];
            const r = bytes[j + 1];
            const g = bytes[j + 2];
            const b = bytes[j + 3];
            bytes[j] = b;
            bytes[j + 1] = g;
            bytes[j + 2] = r;
            bytes[j + 3] = a;
        }
    }

    return image_from_argb32(bytes, best_w, best_h);
}

fn icon_from_theme(name: []const u8) ?*pixman.Image {
    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = find_icon_path(name, &pathbuf) orelse return null;
    if (mem.endsWith(u8, path, ".png")) return icon_from_png(path);
    log.debug("unsupported themed icon format for {s}", .{path});
    return null;
}

fn build_icon_bases() void {
    icon_bases_len = 0;

    const max_bases = icon_bases.len;
    const add_base = struct {
        fn add(base: []const u8) void {
            if (icon_bases_len >= max_bases) return;
            icon_bases[icon_bases_len] = ctx.gpa.dupe(u8, base) catch return;
            icon_bases_len += 1;
        }
    }.add;

    if (ctx.env.get("XDG_DATA_HOME")) |xd| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (fmt.bufPrint(&buf, "{s}/icons", .{xd})) |p| {
            add_base(p);
        } else |_| {}
    }
    if (ctx.env.get("HOME")) |home| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (fmt.bufPrint(&buf, "{s}/.icons", .{home})) |p| {
            add_base(p);
        } else |_| {}
    }
    const data_dirs = ctx.env.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var dirs = mem.tokenizeScalar(u8, data_dirs, ':');
    while (dirs.next()) |d| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (fmt.bufPrint(&buf, "{s}/icons", .{d})) |p| {
            add_base(p);
        } else |_| {}
    }
    add_base("/usr/share/pixmaps");
}

fn find_icon_path(name: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const themes = [_][]const u8{
        "Adwaita", "Papirus", "breeze", "hicolor", "oxygen", "Tango",
        "elementary", "ePapirus", "Numix",
    };
    const sizes = [_][]const u8{ "32x32", "48x48", "24x24", "22x22", "16x16", "64x64" };
    // Freedesktop icon-theme categories; icons also land directly in the size
    // directory, so a bare `{size}/{name}.png` is tried as well.
    const subdirs = [_][]const u8{
        "actions", "apps", "categories", "devices", "emblems", "emotes",
        "filesystems", "intl", "mimetypes", "places", "status", "stock", "",
    };

    for (icon_bases[0..icon_bases_len]) |base| {
        for (themes) |theme| {
            for (sizes) |size| {
                for (subdirs) |subdir| {
                    const p = if (subdir.len == 0)
                        fmt.bufPrint(buf, "{s}/{s}/{s}/{s}.png", .{ base, theme, size, name }) catch continue
                    else
                        fmt.bufPrint(buf, "{s}/{s}/{s}/{s}/{s}.png", .{ base, theme, size, subdir, name }) catch continue;
                    if (file_exists(p)) return p;
                }
            }
        }
        const p = fmt.bufPrint(buf, "{s}/{s}.png", .{ base, name }) catch continue;
        if (file_exists(p)) return p;
    }
    return null;
}

fn file_exists(path: []const u8) bool {
    const fd = posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    posix.close(fd);
    return true;
}

fn icon_from_png(path: []const u8) ?*pixman.Image {
    const fd = posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer posix.close(fd);

    var data = std.ArrayList(u8).empty;
    defer data.deinit(ctx.gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch break;
        if (n == 0) break;
        data.appendSlice(ctx.gpa, buf[0..n]) catch return null;
        if (data.items.len > 1 << 20) return null;
    }

    const decoded = decode_png(ctx.gpa, data.items) catch return null;
    defer ctx.gpa.free(decoded.rgba);
    return image_from_argb32(decoded.rgba, @intCast(decoded.width), @intCast(decoded.height));
}

const DecodedPng = struct {
    width: u32,
    height: u32,
    /// RGBA8 pixels in a8r8g8b8 memory order (b, g, r, a on little endian).
    rgba: []u8,
};

fn decode_png(allocator: std.mem.Allocator, data: []const u8) !DecodedPng {
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (data.len < 8 or !mem.eql(u8, data[0..8], &signature)) return error.NotPng;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;

    var idat = std.ArrayList(u8).empty;
    defer idat.deinit(allocator);

    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const ctype = data[pos + 4 ..][0..4];
        if (pos + 8 + len > data.len) return error.TruncatedPng;
        const cdata = data[pos + 8 ..][0..len];

        if (mem.eql(u8, ctype, "IHDR")) {
            if (len < 13) return error.TruncatedPng;
            width = std.mem.readInt(u32, cdata[0..4], .big);
            height = std.mem.readInt(u32, cdata[4..8], .big);
            bit_depth = cdata[8];
            color_type = cdata[9];
            interlace = cdata[12];
        } else if (mem.eql(u8, ctype, "IDAT")) {
            try idat.appendSlice(allocator, cdata);
        } else if (mem.eql(u8, ctype, "IEND")) {
            break;
        }
        pos += 12 + len;
    }

    if (width == 0 or height == 0 or bit_depth != 8) return error.UnsupportedPng;
    const channels: usize = switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // rgb
        4 => 2, // grayscale + alpha
        6 => 4, // rgba
        else => return error.UnsupportedPng,
    };
    if (interlace != 0) return error.UnsupportedPng;

    var in: std.Io.Reader = .fixed(idat.items);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&in, .zlib, &window);

    const stride = @as(usize, width) * channels;
    const row_bytes = stride + 1;
    const expected = row_bytes * @as(usize, height);
    const raw = try allocator.alloc(u8, expected);
    defer allocator.free(raw);

    var out: std.Io.Writer = .fixed(raw);
    const written = try decompress.reader.streamRemaining(&out);
    if (written != expected) return error.CorruptPng;

    // Reverse the per-scanline filters.
    const prev = try allocator.alloc(u8, stride);
    defer allocator.free(prev);
    @memset(prev, 0);
    for (0..height) |y| {
        const row = raw[y * row_bytes ..][0..row_bytes];
        const filter = row[0];
        const cur = row[1..];
        unfilter(filter, cur, prev, channels);
        @memcpy(prev, cur);
    }

    // Convert to a8r8g8b8 memory order (b, g, r, a on little endian).
    const rgba = try allocator.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    errdefer allocator.free(rgba);
    for (0..height) |y| {
        const row = raw[y * row_bytes + 1 ..][0..stride];
        for (0..width) |x| {
            const s = x * channels;
            const d = (y * @as(usize, width) + x) * 4;
            switch (color_type) {
                0 => {
                    const g = row[s];
                    rgba[d] = g;
                    rgba[d + 1] = g;
                    rgba[d + 2] = g;
                    rgba[d + 3] = 255;
                },
                2 => {
                    rgba[d] = row[s + 2]; // b
                    rgba[d + 1] = row[s + 1]; // g
                    rgba[d + 2] = row[s]; // r
                    rgba[d + 3] = 255;
                },
                4 => {
                    const g = row[s];
                    rgba[d] = g;
                    rgba[d + 1] = g;
                    rgba[d + 2] = g;
                    rgba[d + 3] = row[s + 1];
                },
                6 => {
                    rgba[d] = row[s + 2]; // b
                    rgba[d + 1] = row[s + 1]; // g
                    rgba[d + 2] = row[s]; // r
                    rgba[d + 3] = row[s + 3]; // a
                },
                else => unreachable,
            }
        }
    }

    return .{ .width = width, .height = height, .rgba = rgba };
}

fn unfilter(filter: u8, cur: []u8, prev: []const u8, channels: usize) void {
    switch (filter) {
        0 => {}, // none
        1 => for (channels..cur.len) |i| {
            cur[i] +%= cur[i - channels];
        }, // sub
        2 => for (0..cur.len) |i| {
            cur[i] +%= prev[i];
        }, // up
        3 => for (0..cur.len) |i| {
            const left: u16 = if (i >= channels) cur[i - channels] else 0;
            cur[i] +%= @intCast(@divTrunc(left + @as(u16, prev[i]), 2));
        }, // average
        4 => for (0..cur.len) |i| {
            const a: u8 = if (i >= channels) cur[i - channels] else 0;
            const b: u8 = prev[i];
            const c: u8 = if (i >= channels) prev[i - channels] else 0;
            cur[i] +%= paeth(a, b, c);
        }, // paeth
        else => unreachable,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ---------------------------------------------------------------------------
// Snapshot publication (dbus thread).
// ---------------------------------------------------------------------------

fn publish() void {
    const snap = build_snapshot() orelse return;
    snapshot_mutex.lockUncancelable(ctx.io);
    defer snapshot_mutex.unlock(ctx.io);
    if (current_snapshot) |old| old.unref();
    current_snapshot = snap;
    posix.eventfd_notify(wake_fd);
}

fn build_snapshot() ?*Snapshot {
    const spacing: i32 = @intCast(@max(ctx.cfg.bar.systray.spacing, 1));
    const target: i32 = @intCast(target_height);

    var count: usize = 0;
    if (target > 0) {
        for (items.items) |it| {
            if (it.icon != null) count += 1;
        }
    }
    const total: i32 = if (count > 0) @intCast(@as(i64, @intCast(count)) * @as(i64, target + spacing) - @as(i64, spacing)) else 0;
    log.debug("systray snapshot: {} icons, width {}, target {}", .{ count, total, target });

    const strip: ?*pixman.Image = if (total > 0) blk: {
        const image = pixman.Image.createBits(.a8r8g8b8, total, target, null, 0) orelse return null;
        errdefer _ = image.unref();

        const bg = render_utils.color(ctx.cfg.bar.scheme.normal.bg);
        const rect = [_]pixman.Rectangle16{.{
            .x = 0,
            .y = 0,
            .width = @intCast(@min(total, std.math.maxInt(u16))),
            .height = @intCast(@min(target, std.math.maxInt(u16))),
        }};
        _ = pixman.Image.fillRectangles(.src, image, &bg, 1, &rect);

        var x: i32 = spacing;
        for (items.items) |it| {
            const icon = it.icon orelse continue;
            const scaled = if (icon.getWidth() == target and icon.getHeight() == target) use_direct: {
                // reset a possibly stale transform left over from an earlier scale
                var identity: pixman.Transform = undefined;
                pixman.Transform.initIdentity(&identity);
                _ = icon.setTransform(&identity);
                break :use_direct icon;
            } else scale_image(icon, @intCast(target)) orelse continue;
            defer if (scaled != icon) {
                _ = scaled.unref();
            };

            pixman.Image.composite32(.over, scaled, null, image, 0, 0, 0, 0, x, 0, target, target);
            x += target + spacing;
        }
        break :blk image;
    } else null;

    const snap = ctx.gpa.create(Snapshot) catch return null;
    snap.* = .{
        .strip = strip,
        .width = total,
        .height = @intCast(target),
    };
    return snap;
}

fn scale_image(src: *pixman.Image, target: u32) ?*pixman.Image {
    if (target == 0) return null;
    const dst = pixman.Image.createBits(.a8r8g8b8, @intCast(target), @intCast(target), null, 0) orelse return null;
    errdefer _ = dst.unref();

    const clear = pixman.Color{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
    const rect = [_]pixman.Rectangle16{.{
        .x = 0,
        .y = 0,
        .width = @intCast(@min(@as(i32, @intCast(target)), std.math.maxInt(u16))),
        .height = @intCast(@min(@as(i32, @intCast(target)), std.math.maxInt(u16))),
    }};
    _ = pixman.Image.fillRectangles(.src, dst, &clear, 1, &rect);

    const sw = src.getWidth();
    const sh = src.getHeight();
    if (sw <= 0 or sh <= 0) return null;

    var transform: pixman.Transform = undefined;
    pixman.Transform.initScale(
        &transform,
        @enumFromInt(@divTrunc(@as(i32, sw) << 16, @as(i32, @intCast(target)))),
        @enumFromInt(@divTrunc(@as(i32, sh) << 16, @as(i32, @intCast(target)))),
    );
    _ = src.setTransform(&transform);
    _ = src.setFilter(.bilinear, &.{}, 0);
    pixman.Image.composite32(.over, src, null, dst, 0, 0, 0, 0, 0, 0, @intCast(target), @intCast(target));
    return dst;
}

// ---------------------------------------------------------------------------
// Signal serial for outbound watcher signals (dbus thread).
// ---------------------------------------------------------------------------

var fire_serial: u32 = 0xFF00_0000;

test "paeth predictor" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 10), paeth(10, 5, 3));
    try testing.expectEqual(@as(u8, 10), paeth(5, 10, 3));
    try testing.expectEqual(@as(u8, 3), paeth(3, 5, 10));
    try testing.expectEqual(@as(u8, 0), paeth(0, 0, 0));
    try testing.expectEqual(@as(u8, 7), paeth(7, 4, 2));
}

test "unfilter sub and up" {
    const testing = std.testing;

    var cur = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const prev = [_]u8{ 10, 20, 30, 40, 50, 60 };
    // "up" filter: cur[i] = cur[i] + prev[i]
    cur = .{ 1, 2, 3, 4, 5, 6 };
    unfilter(2, &cur, &prev, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 11, 22, 33, 44, 55, 66 }, &cur);

    // "sub" filter: cur[i] = cur[i] + cur[i - channels]
    cur = .{ 10, 10, 10, 20, 20, 20 };
    unfilter(1, &cur, &prev, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 10, 30, 30, 30 }, &cur);
}

test "decode_png decodes a minimal rgb png" {
    const testing = std.testing;

    // A 2x1 RGB png (8-bit, no interlace), stored-block zlib stream, filter 0.
    // Pixels: left = red (255,0,0), right = green (0,255,0).
    // Raw scanline data: [0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00]
    const png = [_]u8{
        0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a,
        // IHDR: width=2 height=1 depth=8 color=2
        0x00, 0x00, 0x00, 0x0d,
        'I', 'H', 'D', 'R',
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        // IDAT: zlib(78 01) + stored block + 7 raw bytes + adler32
        0x00, 0x00, 0x00, 0x12,
        'I', 'D', 'A', 'T',
        0x78, 0x01,
        0x01,
        0x07, 0x00,
        0xf8, 0xff,
        0x00, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00,
        0x07, 0xff, 0x01, 0xff,
        0x00, 0x00, 0x00, 0x00,
        // IEND
        0x00, 0x00, 0x00, 0x00,
        'I', 'E', 'N', 'D',
        0xae, 0x42, 0x60, 0x82,
    };

    const decoded = try decode_png(testing.allocator, &png);
    defer testing.allocator.free(decoded.rgba);
    try testing.expectEqual(@as(u32, 2), decoded.width);
    try testing.expectEqual(@as(u32, 1), decoded.height);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 }, decoded.rgba);
}
