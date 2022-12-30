const std = @import("std");
const gnorp = @import("main.zig");

test {
    std.testing.refAllDecls(@This());
}

var _out: std.fs.File.Writer = undefined;
var _lock: std.Thread.Mutex = .{};
var _debug = false;

/// init initializes the log with the given output writer.
pub fn init(writer: std.fs.File.Writer, debug_mode: bool) void {
    _lock.lock();
    _out = writer;
    _debug = debug_mode;
    _lock.unlock();
}

/// debug logs a debug message. This will only output something if the logger
/// was initialized with debug_mode = true.
///
/// The optional `src` provides call-site source information that is also printed.
/// It can be retrieved with the builtin function `@src()`.
pub inline fn debug(comptime src: ?std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    if (!_debug) return;
    if (src) |s| {
        _lock.lock();
        const file = if (std.mem.startsWith(u8, s.file, gnorp.config.build_prefix))
            s.file[gnorp.config.build_prefix.len..]
        else
            std.fs.path.basename(s.file);
        _out.print("[debug] {s}:{}: ", .{
            file,
            s.line,
        }) catch unreachable;
        _out.print(fmt ++ "\n", args) catch unreachable;
        _lock.unlock();
    } else {
        write("[debug] " ++ fmt, args);
    }
}

/// info logs an informational message.
pub inline fn info(comptime fmt: []const u8, args: anytype) void {
    write("[info] " ++ fmt, args);
}

/// err logs an error message.
pub inline fn err(comptime fmt: []const u8, args: anytype) void {
    write("[error] " ++ fmt, args);
}

fn write(comptime fmt: []const u8, args: anytype) void {
    _lock.lock();
    _out.print(fmt ++ "\n", args) catch unreachable;
    _lock.unlock();
}
