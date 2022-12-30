const std = @import("std");
const glfw = @import("glfw");
const gnorp = @import("main.zig");
const Id = glfw.Joystick.Id;

test {
    std.testing.refAllDecls(@This());
}

/// cursor_pos defines the current X/Y cursor position.
pub var cursor_pos: [2]f32 = .{ 0, 0 };

/// cursor_delta defines the difference between the current-
/// and previous frame's cursor positions.
pub var cursor_delta: [2]f32 = .{ 0, 0 };

/// controllers holds all connected gamepads.
/// Each non-null entry can be actively used for input.
pub var controllers: [@enumToInt(glfw.Joystick.Id.last) + 1]?glfw.Joystick = undefined;

pub fn init() !void {
    std.mem.set(?glfw.Joystick, &controllers, null);
    glfw.Joystick.setCallback(joystickCallback);

    // Find initial connected gamepads.
    var id: u32 = 0;
    while (id <= @enumToInt(Id.last)) : (id += 1) {
        const js = glfw.Joystick{ .jid = @intToEnum(Id, id) };
        if (try js.present())
            try connectGamepad(js);
    }
}

pub fn deinit() void {}

/// update the input state.
pub fn update() !void {
    const pos = try gnorp.graphics.window.getCursorPos();
    cursor_delta[0] = cursor_pos[0] - @floatCast(f32, pos.xpos);
    cursor_delta[1] = cursor_pos[1] - @floatCast(f32, pos.ypos);
    cursor_pos[0] = @floatCast(f32, pos.xpos);
    cursor_pos[1] = @floatCast(f32, pos.ypos);
}

/// getController returns the index for the nth /connected/ controller.
/// Returns null if there are not enough connected controllers.
pub fn getController(n: usize) ?usize {
    var count: usize = 0;
    for (controllers) |c, i| {
        if (c != null) {
            if (count == n)
                return i;
            count += 1;
        }
    }
    return null;
}

fn joystickCallback(js: glfw.Joystick, event: glfw.Joystick.Event) void {
    const connected = event == .connected;
    if (connected) {
        connectGamepad(js) catch |err| {
            gnorp.log.debug(@src(), "{}", .{err});
        };
    } else {
        disconnectGamepad(js) catch |err| {
            gnorp.log.debug(@src(), "{}", .{err});
        };
    }
}

fn connectGamepad(js: glfw.Joystick) !void {
    if (!js.isGamepad()) return;
    const id = @intCast(usize, @enumToInt(js.jid));
    controllers[id] = js;
    if (try js.getName()) |name| {
        gnorp.log.debug(@src(), "controller {} ({s}) connected", .{ id, name });
    } else {
        gnorp.log.debug(@src(), "controller {} connected", .{id});
    }
}

fn disconnectGamepad(js: glfw.Joystick) !void {
    const id = @intCast(usize, @enumToInt(js.jid));
    if (controllers[id] != null) {
        controllers[id] = null;
        gnorp.log.debug(@src(), "controller {} disconnected", .{id});
    }
}
