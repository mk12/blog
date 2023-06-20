// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reporter = @This();

allocator: Allocator,
message: ?[]const u8,

pub fn init(allocator: Allocator) Reporter {
    return Reporter{ .allocator = allocator, .message = null };
}

pub const Error = error{ErrorWasReported};

pub fn fail(self: *Reporter, comptime format: []const u8, args: anytype) Error {
    if (@inComptime()) @compileError(std.fmt.comptimePrint(format, args));
    self.message = std.fmt.allocPrint(self.allocator, format, args) catch unreachable;
    return error.ErrorWasReported;
}

pub const Location = struct {
    line: u16 = 1,
    column: u16 = 1,
};

pub fn failAt(
    self: *Reporter,
    filename: []const u8,
    location: Location,
    comptime format: []const u8,
    args: anytype,
) Error {
    return self.fail(
        "{s}:{}:{}: " ++ format,
        .{ filename, location.line, location.column } ++ args,
    );
}

pub fn showMessage(self: *const Reporter, err: anyerror) void {
    if (err != error.ErrorWasReported) return;
    std.debug.print("\n====== an error was reported: ========\n", .{});
    std.debug.print("{s}", .{self.message.?});
    std.debug.print("\n======================\n", .{});
}

pub fn expectFailure(self: *const Reporter, expected_message: []const u8, result: anytype) !void {
    try testing.expectEqualStrings(expected_message, self.message.?);
    try testing.expectError(error.ErrorWasReported, result);
}

test "fail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = init(arena.allocator());
    const result = reporter.fail("foo: {s}", .{"bar"});
    try reporter.expectFailure("foo: bar", @as(Error!void, result));
}

test "failAt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = init(arena.allocator());
    const result = reporter.failAt("test.txt", .{ .line = 42, .column = 5 }, "foo: {s}", .{"bar"});
    try reporter.expectFailure("test.txt:42:5: foo: bar", @as(Error!void, result));
}
