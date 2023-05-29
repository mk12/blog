// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Reporter = @This();

filename: []const u8 = "<input>",
out: ?*std.ArrayList(u8) = null, // defaults to using std.log.err

pub const Location = struct {
    line: u16 = 1,
    column: u16 = 1,
};

pub const Error = error{ErrorWasReported} || std.mem.Allocator.Error;

pub fn fail(self: Reporter, location: Location, comptime format: []const u8, args: anytype) Error {
    const full_format = "{s}:{}:{}: " ++ format;
    const full_args = .{ self.filename, location.line, location.column } ++ args;
    if (@inComptime())
        @compileError(std.fmt.comptimePrint(full_format, full_args));
    if (self.out) |out|
        try std.fmt.format(out.writer(), full_format, full_args)
    else
        std.log.err(full_format, full_args);
    return error.ErrorWasReported;
}

test "fail" {
    var log = std.ArrayList(u8).init(testing.allocator);
    defer log.deinit();
    var reporter = Reporter{ .filename = "test.txt", .out = &log };
    try testing.expectEqual(
        Error.ErrorWasReported,
        reporter.fail(.{ .line = 42, .column = 5 }, "foo: {s}", .{"bar"}),
    );
    try testing.expectEqualStrings("test.txt:42:5: foo: bar", log.items);
}
