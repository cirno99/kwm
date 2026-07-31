const std = @import("std");

var log_fd: i32 = -1;

extern "c" fn write(fd: i32, buf: [*]const u8, count: usize) isize;
extern "c" fn getpid() i32;
extern "c" fn open(path: [*:0]const u8, flags: i32, mode: u32) i32;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn _exit(status: i32) noreturn;
extern "c" fn sigaction(sig: i32, act: ?*const anyopaque, oldact: ?*anyopaque) i32;
extern "c" fn clock_gettime(clk_id: i32, tp: *timespec) i32;
extern "c" fn backtrace(buffer: [*]*anyopaque, size: i32) i32;
extern "c" fn backtrace_symbols_fd(buffer: [*]*anyopaque, size: i32, fd: i32) void;
extern "c" fn localtime_r(timep: *const i64, result: *tm) ?*tm;

const O_RDWR: i32 = 2;
const O_CREAT: i32 = 0o100;
const O_APPEND: i32 = 0o2000;
const O_CLOEXEC: i32 = 0o2000000;

const CLOCK_REALTIME: i32 = 0;

const timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const tm = extern struct {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
};

const SigAction = extern struct {
    sa_handler: ?*const fn (i32) callconv(.c) void,
    sa_flags: u64,
    sa_restorer: ?*const fn () callconv(.c) void,
    sa_mask: u64,
};

const MAX_BACKTRACE: i32 = 32;

fn write2Digits(buf: []u8, idx: *usize, v: i32) void {
    const u = @as(u32, @intCast(v));
    buf[idx.*] = "0123456789"[u / 10];
    idx.* += 1;
    buf[idx.*] = "0123456789"[u % 10];
    idx.* += 1;
}

fn write4Digits(buf: []u8, idx: *usize, v: i32) void {
    const u = @as(u32, @intCast(v));
    buf[idx.*] = "0123456789"[u / 1000];
    idx.* += 1;
    buf[idx.*] = "0123456789"[u / 100 % 10];
    idx.* += 1;
    buf[idx.*] = "0123456789"[u / 10 % 10];
    idx.* += 1;
    buf[idx.*] = "0123456789"[u % 10];
    idx.* += 1;
}

fn writeTimestamp(fd: i32) void {
    var ts: timespec = undefined;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return;

    var t: tm = undefined;
    if (localtime_r(&ts.tv_sec, &t) == null) return;

    var buf: [48]u8 = undefined;
    var i: usize = 0;

    write4Digits(&buf, &i, t.tm_year + 1900);
    buf[i] = '-'; i += 1;
    write2Digits(&buf, &i, t.tm_mon + 1);
    buf[i] = '-'; i += 1;
    write2Digits(&buf, &i, t.tm_mday);
    buf[i] = ' '; i += 1;
    write2Digits(&buf, &i, t.tm_hour);
    buf[i] = ':'; i += 1;
    write2Digits(&buf, &i, t.tm_min);
    buf[i] = ':'; i += 1;
    write2Digits(&buf, &i, t.tm_sec);
    buf[i] = '.'; i += 1;

    var ns = @as(u32, @intCast(ts.tv_nsec));
    var ns_buf: [9]u8 = undefined;
    var idx: usize = 9;
    while (idx > 0) {
        idx -= 1;
        ns_buf[idx] = "0123456789"[ns % 10];
        ns = @divTrunc(ns, 10);
    }
    for (ns_buf) |c| { buf[i] = c; i += 1; }

    buf[i] = '\n';
    i += 1;

    _ = write(fd, &buf, i);
}

fn writeStack(fd: i32) void {
    const label = "Stack:\n";
    _ = write(fd, label, label.len);

    var trace: [@as(usize, @intCast(MAX_BACKTRACE))]*anyopaque = undefined;
    const count = backtrace(&trace, MAX_BACKTRACE);
    if (count > 0) {
        backtrace_symbols_fd(&trace, count, fd);
    }
}

fn crash_handler(sig: i32) callconv(.c) void {
    const fd = log_fd;
    if (fd >= 0) {
        const name = switch (sig) {
            11 => "SIGSEGV",
            6 => "SIGABRT",
            7 => "SIGBUS",
            8 => "SIGFPE",
            4 => "SIGILL",
            31 => "SIGSYS",
            5 => "SIGTRAP",
            else => "SIGUNKN",
        };
        const pid = getpid();

        var buf: [256]u8 = undefined;
        const prefix = "FATAL CRASH: ";
        const suffix = " (pid ";
        const nl = ")\n";
        var i: usize = 0;
        for (prefix) |c| { buf[i] = c; i += 1; }
        for (name) |c| { buf[i] = c; i += 1; }
        for (suffix) |c| { buf[i] = c; i += 1; }
        var n = @as(u32, @intCast(pid));
        const digit_start = i;
        if (n == 0) {
            buf[i] = '0'; i += 1;
        } else {
            while (n > 0) {
                buf[i] = "0123456789"[n % 10];
                n = @divTrunc(n, 10);
                i += 1;
            }
            var j = digit_start;
            var k = i - 1;
            while (j < k) {
                const tmp = buf[j];
                buf[j] = buf[k];
                buf[k] = tmp;
                j += 1;
                k -= 1;
            }
        }
        for (nl) |c| { buf[i] = c; i += 1; }
        _ = write(fd, &buf, i);

        writeTimestamp(fd);
        writeStack(fd);
    }
    _exit(1);
}

pub fn init() void {
    var path_buf: [256:0]u8 = undefined;
    var path_len: usize = 0;

    if (getenv("HOME")) |home| {
        const home_slice = std.mem.sliceTo(home, 0);
        const suffix = "/.config/kwm/kwm.log";
        if (home_slice.len + suffix.len < path_buf.len) {
            @memcpy(path_buf[0..home_slice.len], home_slice);
            @memcpy(path_buf[home_slice.len..home_slice.len + suffix.len], suffix);
            path_len = home_slice.len + suffix.len;
        }
    }

    if (path_len == 0) return;

    path_buf[path_len] = 0;
    const fd = open(&path_buf, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o644);
    if (fd >= 0) log_fd = fd;

    inline for (.{ 11, 6, 7, 8, 4, 31, 5 }) |sig| {
        var act = SigAction{
            .sa_handler = crash_handler,
            .sa_flags = 0,
            .sa_restorer = null,
            .sa_mask = 0,
        };
        _ = sigaction(sig, &act, null);
    }
}

pub fn log_panic(msg: []const u8) void {
    const fd = log_fd;
    if (fd < 0) return;

    var buf: [512]u8 = undefined;
    var i: usize = 0;

    const header = "PANIC: ";
    for (header) |c| { buf[i] = c; i += 1; }
    for (msg) |c| {
        if (i >= buf.len) break;
        buf[i] = c;
        i += 1;
    }
    if (i < buf.len) {
        buf[i] = '\n';
        i += 1;
    }
    _ = write(fd, &buf, i);

    writeTimestamp(fd);
    writeStack(fd);
}
