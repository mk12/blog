// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const builtin = @import("builtin");
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
    const full_format = "{s}:{}:{}: " ++ format;
    const full_args = .{ filename, location.line, location.column } ++ args;
    if (@inComptime())
        @compileError(std.fmt.comptimePrint(full_format, full_args));
    if (std.fmt.bufPrint(&self.buffer, full_format, full_args)) |result| {
        self.length = result.len;
    } else |err| switch (err) {
        error.NoSpaceLeft => {
            const truncated = " (truncated)";
            @memcpy(self.buffer[self.buffer.len - truncated.len ..], truncated);
        },
    }
    return error.ErrorWasReported;
}

pub fn message(self: *const Reporter) []const u8 {
    return self.buffer[0..self.length];
}

pub fn expectFailure(self: *const Reporter, expected: []const u8, result: anytype) !void {
    try testing.expectEqualStrings(expected, self.message());
    try testing.expectError(error.ErrorWasReported, result);
}

test "no failure" {
    const reporter = Reporter{};
    try testing.expectEqualStrings("", reporter.message());
}

test "fail" {
    var reporter = Reporter{};
    try testing.expectEqual(
        error.ErrorWasReported,
        reporter.fail("test.txt", .{ .line = 42, .column = 5 }, "foo: {s}", .{"bar"}),
    );
    try testing.expectEqualStrings("test.txt:42:5: foo: bar", reporter.message());
}
