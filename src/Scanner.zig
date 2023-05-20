// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fmtEscapes = std.zig.fmtEscapes;
const Scanner = @This();
const testing = std.testing;

allocator: Allocator,
source: []const u8,
pos: Position = .{},
filename: []const u8 = "<input>",
error_message: ?[]const u8 = null,

pub const Error = error{ScanError} || std.fmt.AllocPrintError;

pub const Position = struct {
    offset: u32 = 0,
    line: u16 = 1,
    column: u16 = 1,
};

pub const Token = struct {
    text: []const u8,
    pos: Position,
};

pub fn init(allocator: Allocator, source: []const u8) Scanner {
    return Scanner{ .allocator = allocator, .source = source };
}

pub fn deinit(self: *Scanner) void {
    if (self.error_message) |message| {
        self.allocator.free(message);
    }
}

pub fn eof(self: *const Scanner) bool {
    return self.pos.offset == self.source.len;
}

pub fn peek(self: *const Scanner) ?u8 {
    return if (self.eof()) null else self.source[self.pos.offset];
}

pub fn eat(self: *Scanner) ?u8 {
    if (self.eof()) return null;
    const character = self.source[self.pos.offset];
    self.pos.offset += 1;
    if (character == '\n') {
        self.pos.line += 1;
        self.pos.column = 1;
    } else {
        self.pos.column += 1;
    }
    return character;
}

pub fn consumeBytes(self: *Scanner, count: usize) Error!Token {
    assert(count > 0);
    const start = self.pos;
    for (0..count) |_|
        _ = self.eat() orelse return self.fail("unexpected EOF", .{});
    return Token{
        .text = self.source[start.offset..self.pos.offset],
        .pos = start,
    };
}

pub fn consumeUntil(self: *Scanner, end: u8) Error!Token {
    const start = self.pos;
    while (self.eat()) |character| {
        if (character == end) {
            return Token{
                .text = self.source[start.offset .. self.pos.offset - 1],
                .pos = start,
            };
        }
    }
    return self.fail("unexpected EOF looking for \"{}\"", .{fmtEscapes(&[_]u8{end})});
}

pub fn skipWhitespace(self: *Scanner) void {
    while (true) {
        switch (self.peek()) {
            ' ', '\t', '\n' => {},
            else => break,
        }
        _ = self.eat();
    }
}

pub fn expect(self: *Scanner, comptime expected: []const u8) Error!void {
    const offset = self.pos.offset;
    const actual = self.source[offset..std.math.min(offset + expected.len, self.source.len)];
    if (!std.mem.eql(u8, actual, expected))
        return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(expected), fmtEscapes(actual) });
    self.pos.offset += @intCast(u32, expected.len);
    self.pos.line += @intCast(u16, comptime std.mem.count(u8, expected, "\n"));
    self.pos.column = if (comptime std.mem.lastIndexOfScalar(u8, expected, '\n')) |idx|
        expected.len - idx
    else
        self.pos.column + @intCast(u16, expected.len);
}

pub fn fail(self: *Scanner, comptime format: []const u8, args: anytype) Error {
    return self.failAt(self.pos, format, args);
}

pub fn failOn(self: *Scanner, token: Token, comptime format: []const u8, args: anytype) Error {
    return self.failAt(token.pos, "\"{s}\": " ++ format, .{token.text} ++ args);
}

pub fn failAt(self: *Scanner, pos: Position, comptime format: []const u8, args: anytype) Error {
    self.error_message = try std.fmt.allocPrint(
        self.allocator,
        "{s}:{}:{}: " ++ format,
        .{ self.filename, pos.line, pos.column } ++ args,
    );
    return error.ScanError;
}

test "empty input" {
    var scanner = init(testing.allocator, "");
    defer scanner.deinit();
    try testing.expect(scanner.eof());
    try testing.expectEqual(@as(?u8, null), scanner.peek());
    try testing.expectEqual(@as(?u8, null), scanner.eat());
}

test "single character" {
    var scanner = init(testing.allocator, "x");
    defer scanner.deinit();
    try testing.expect(!scanner.eof());
    try testing.expectEqual(@as(?u8, 'x'), scanner.peek());
    try testing.expect(!scanner.eof());
    try testing.expectEqual(@as(?u8, 'x'), scanner.eat());
    try testing.expect(scanner.eof());
}

test "consumeBytes" {
    var scanner = init(testing.allocator, "abc");
    defer scanner.deinit();
    try testing.expectEqualDeep(Token{
        .text = "ab",
        .pos = Position{ .offset = 0, .line = 1, .column = 1 },
    }, try scanner.consumeBytes(2));
    try testing.expectEqualDeep(Token{
        .text = "c",
        .pos = Position{ .offset = 2, .line = 1, .column = 3 },
    }, try scanner.consumeBytes(1));
    try testing.expect(scanner.eof());
}

test "consumeUntil" {
    var scanner = init(testing.allocator, "one\ntwo\n");
    defer scanner.deinit();
    try testing.expectEqualDeep(Token{
        .text = "one",
        .pos = Position{ .offset = 0, .line = 1, .column = 1 },
    }, try scanner.consumeUntil('\n'));
    try testing.expectEqualDeep(Token{
        .text = "two",
        .pos = Position{ .offset = 4, .line = 2, .column = 1 },
    }, try scanner.consumeUntil('\n'));
    try testing.expect(scanner.eof());
}

test "fail" {
    var scanner = init(testing.allocator, "foo\nbar.\n");
    scanner.filename = "test.txt";
    defer scanner.deinit();
    _ = try scanner.consumeUntil('.');
    try testing.expectEqual(@as(Error, error.ScanError), scanner.fail("oops: {}", .{123}));
    try testing.expectEqualStrings("test.txt:2:5: oops: 123", scanner.error_message.?);
}

test "failOn" {
    var scanner = init(testing.allocator, "foo\nbar.\n");
    scanner.filename = "test.txt";
    defer scanner.deinit();
    _ = try scanner.consumeUntil('\n');
    const token = try scanner.consumeUntil('.');
    try testing.expectEqual(@as(Error, error.ScanError), scanner.failOn(token, "oops: {}", .{123}));
    try testing.expectEqualStrings("test.txt:2:1: \"bar\": oops: 123", scanner.error_message.?);
}
