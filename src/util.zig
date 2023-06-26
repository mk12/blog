// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");

pub const Timer = struct {
    inner: ?std.time.Timer,

    pub fn start(enabled: bool) !Timer {
        return Timer{ .inner = if (enabled) try std.time.Timer.start() else null };
    }

    pub fn log(self: *Timer, comptime format: []const u8, args: anytype) void {
        var inner = self.inner orelse return;
        std.log.info(format ++ " in {d:.2} ms", args ++ .{nsToMs(inner.lap())});
    }

    pub fn logEach(self: *Timer, comptime format: []const u8, args: anytype, count: usize) void {
        var inner = self.inner orelse return;
        const total = nsToMs(inner.lap());
        std.log.info(format ++ " in {d:.2} ms ({d:.2} ms each)", args ++ .{ total, total / @intToFloat(f64, count) });
    }

    fn nsToMs(duration: u64) f64 {
        return @intToFloat(f64, duration) / 1e6;
    }
};
