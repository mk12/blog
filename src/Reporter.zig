// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements error reporting. When you report an error, it formats
//! the message in a buffer and returns error.ErrorWasReported, which you can
//! then handle farther up the call stack (for example, by logging the message).
//! The failAt method makes it easy to associate errors with source locations.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Reporter = @This();

allocator: Allocator,
message: ?[]const u8,

pub fn init(allocator: Allocator) Reporter {
    return Reporter{ .allocator = allocator, .message = null };
}

pub const Error = error{ErrorWasReported};

pub fn fail(self: *Reporter, filename: []const u8, location: Location, comptime format: []const u8, args: anytype) Error {
    const full_format = "{s}{}: " ++ format;
    const full_args = .{ filename, location.format() } ++ args;
    if (@inComptime()) @compileError(std.fmt.comptimePrint(full_format, full_args));
    self.message = std.fmt.allocPrint(self.allocator, full_format, full_args) catch unreachable;
    return error.ErrorWasReported;
}

pub fn addNote(self: *Reporter, filename: []const u8, location: Location, comptime format: []const u8, args: anytype) void {
    const full_format = "{s}\n{s}{}: note: " ++ format;
    const full_args = .{ self.message.?, filename, location.format() } ++ args;
    self.message = std.fmt.allocPrint(self.allocator, full_format, full_args) catch unreachable;
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
    const result = reporter.fail("test.txt", .{ .line = 42, .column = 5 }, "foo: {s}", .{"bar"});
    try reporter.expectFailure("test.txt:42:5: foo: bar", @as(Error!void, result));
}

test "addNote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = init(arena.allocator());
    const result = reporter.fail("test.txt", .{ .line = 42, .column = 5 }, "foo: {s}", .{"bar"});
    reporter.addNote("test.txt", .{ .line = 10, .column = 1 }, "{s}", .{"context"});
    try reporter.expectFailure(
        \\test.txt:42:5: foo: bar
        \\test.txt:10:1: note: context
    , @as(Error!void, result));
}

pub const Location = struct {
    line: u16,
    column: u16,

    pub const none = Location{ .line = 0, .column = 0 };

    pub fn fromOffset(source: []const u8, offset: usize) Location {
        const start_of_line = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| i + 1 else 0;
        const num_newlines = std.mem.count(u8, source[0..start_of_line], "\n");
        return Location{
            .line = @intCast(num_newlines + 1),
            .column = @intCast(offset - start_of_line + 1),
        };
    }

    pub fn fromPtr(source: []const u8, ptr: [*]const u8) Location {
        // TODO(https://github.com/ziglang/zig/issues/9646): Should be able to subtract pointers at comptime.
        if (@inComptime()) return Location{ .line = 0, .column = 0 }; // use 0 to indicate it's fake
        // TODO(https://github.com/ziglang/zig/issues/1738): @intFromPtr should be unnecessary.
        return fromOffset(source, @intFromPtr(ptr) - @intFromPtr(source.ptr));
    }

    fn format(self: Location) std.fmt.Formatter(formatFn) {
        return .{ .data = self };
    }

    fn formatFn(self: Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.line == none.line and self.column == none.column) return;
        try writer.print(":{}:{}", .{ self.line, self.column });
    }
};

test "Location.fromOffset" {
    try testing.expectEqualDeep(Location{ .line = 1, .column = 1 }, Location.fromOffset("", 0));
    try testing.expectEqualDeep(Location{ .line = 1, .column = 1 }, Location.fromOffset("x", 0));
    try testing.expectEqualDeep(Location{ .line = 1, .column = 2 }, Location.fromOffset("x", 1));
    try testing.expectEqualDeep(Location{ .line = 1, .column = 1 }, Location.fromOffset("a\n\nbc", 0));
    try testing.expectEqualDeep(Location{ .line = 1, .column = 2 }, Location.fromOffset("a\n\nbc", 1));
    try testing.expectEqualDeep(Location{ .line = 2, .column = 1 }, Location.fromOffset("a\n\nbc", 2));
    try testing.expectEqualDeep(Location{ .line = 3, .column = 1 }, Location.fromOffset("a\n\nbc", 3));
    try testing.expectEqualDeep(Location{ .line = 3, .column = 2 }, Location.fromOffset("a\n\nbc", 4));
    try testing.expectEqualDeep(Location{ .line = 3, .column = 3 }, Location.fromOffset("a\n\nbc", 5));
}

test "Location.fromPtr" {
    const source = "foo\nbar";
    try testing.expectEqualDeep(Location{ .line = 1, .column = 1 }, Location.fromPtr(source, source.ptr));
    try testing.expectEqualDeep(Location{ .line = 2, .column = 1 }, Location.fromPtr(source, source.ptr + 4));
}

test "Location.format" {
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("", try std.fmt.bufPrint(&buffer, "{}", .{Location.none.format()}));
    try testing.expectEqualStrings(":1:2", try std.fmt.bufPrint(&buffer, "{}", .{(Location{ .line = 1, .column = 2 }).format()}));
}
