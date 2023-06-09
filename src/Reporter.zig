// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Reporter = @This();

length: usize = 0,
buffer: [256]u8 = undefined,

pub const Location = struct {
    line: u16 = 1,
    column: u16 = 1,
};

pub const Error = error{ErrorWasReported};

pub fn fail(
    self: *Reporter,
    filename: []const u8,
    location: Location,
    comptime format: []const u8,
    args: anytype,
) Error {
    return self.failRaw(
        "{s}:{}:{}: " ++ format,
        .{ filename, location.line, location.column } ++ args,
    );
}

pub fn failRaw(self: *Reporter, comptime format: []const u8, args: anytype) Error {
    if (@inComptime())
        @compileError(std.fmt.comptimePrint(format, args));
    if (std.fmt.bufPrint(&self.buffer, format, args)) |result| {
        self.length = result.len;
    } else |err| switch (err) {
        error.NoSpaceLeft => {
            self.length = self.buffer.len;
            const truncated = " (truncated)";
            @memcpy(self.buffer[self.buffer.len - truncated.len ..], truncated);
        },
    }
    return error.ErrorWasReported;
}

pub fn message(self: *const Reporter) []const u8 {
    return self.buffer[0..self.length];
}

pub fn expectFailure(self: *const Reporter, expected_message: []const u8, result: anytype) !void {
    try testing.expectEqualStrings(expected_message, self.message());
    try testing.expectError(error.ErrorWasReported, result);
}

pub fn showMessage(self: *const Reporter, err: anyerror) void {
    if (err != error.ErrorWasReported) return;
    std.debug.print("\n====== an error was reported: ========\n", .{});
    std.debug.print("{s}", .{self.message()});
    std.debug.print("\n======================\n", .{});
}

test "no failure" {
    const reporter = Reporter{};
    try testing.expectEqualStrings("", reporter.message());
}

test "failure" {
    var reporter = Reporter{};
    const result = reporter.fail("test.txt", .{ .line = 42, .column = 5 }, "foo: {s}", .{"bar"});
    try reporter.expectFailure("test.txt:42:5: foo: bar", @as(Error!void, result));
}
