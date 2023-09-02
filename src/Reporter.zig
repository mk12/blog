// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements error reporting. When you report an error, it formats
//! the message in a buffer and returns error.ErrorWasReported, which you can
//! then handle farther up the call stack (for example, by logging the message).
//! The failAt method makes it easy to associate errors with source locations.

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

pub fn failAt(self: *Reporter, filename: []const u8, location: Location, comptime format: []const u8, args: anytype) Error {
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
    try testing.expectError(error.ErrorWasReported, result);
    try testing.expectEqualStrings(expected_message, self.message.?);
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

pub const Location = struct {
    line: u16 = 1,
    column: u16 = 1,

    pub fn fromOffset(source: []const u8, offset: usize) Location {
        const start_of_line = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| i + 1 else 0;
        const num_newlines = std.mem.count(u8, source[0..start_of_line], "\n");
        return Location{
            .line = @intCast(num_newlines + 1),
            .column = @intCast(offset - start_of_line + 1),
        };
    }

    pub fn fromPtr(source: []const u8, ptr: [*]const u8) Location {
        // TODO(https://github.com/ziglang/zig/issues/1738): @intFromPtr should be unnecessary.
        return fromOffset(source, @intFromPtr(ptr) - @intFromPtr(source.ptr));
    }
};

test "Location.fromOffset" {
    try testing.expectEqual(Location{ .line = 1, .column = 1 }, Location.fromOffset("", 0));
    try testing.expectEqual(Location{ .line = 1, .column = 1 }, Location.fromOffset("x", 0));
    try testing.expectEqual(Location{ .line = 1, .column = 2 }, Location.fromOffset("x", 1));
    try testing.expectEqual(Location{ .line = 1, .column = 1 }, Location.fromOffset("a\n\nbc", 0));
    try testing.expectEqual(Location{ .line = 1, .column = 2 }, Location.fromOffset("a\n\nbc", 1));
    try testing.expectEqual(Location{ .line = 2, .column = 1 }, Location.fromOffset("a\n\nbc", 2));
    try testing.expectEqual(Location{ .line = 3, .column = 1 }, Location.fromOffset("a\n\nbc", 3));
    try testing.expectEqual(Location{ .line = 3, .column = 2 }, Location.fromOffset("a\n\nbc", 4));
    try testing.expectEqual(Location{ .line = 3, .column = 3 }, Location.fromOffset("a\n\nbc", 5));
}

test "Location.fromPtr" {
    const source = "foo\nbar";
    try testing.expectEqual(Location{ .line = 1, .column = 1 }, Location.fromPtr(source, source.ptr));
    try testing.expectEqual(Location{ .line = 2, .column = 1 }, Location.fromPtr(source, source.ptr + 4));
}
