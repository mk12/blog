// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const fmtEscapes = std.zig.fmtEscapes;
const Allocator = std.mem.Allocator;
const Scanner = @This();

source: []const u8,
pos: Position = .{},
filename: []const u8 = "<input>",
allocator: ?Allocator,
error_message: ?[]const u8 = null,
log_error: bool = false,

pub const Error = error{ScanError} || std.fmt.AllocPrintError;

pub const Position = struct {
    offset: u32 = 0,
    line: u16 = 1,
    column: u16 = 1,
};

pub const Span = struct {
    pos: Position,
    text: []const u8,
};

pub fn init(allocator: ?Allocator, source: []const u8) Scanner {
    return Scanner{ .allocator = allocator, .source = source };
}

pub fn deinit(self: *Scanner) void {
    if (self.error_message) |message| {
        self.allocator.?.free(message);
    }
}

pub fn initForTest(source: []const u8, options: struct { log_error: bool }) Scanner {
    var scanner = init(testing.allocator, source);
    scanner.log_error = options.log_error;
    return scanner;
}

pub fn eof(self: *const Scanner) bool {
    return self.pos.offset == self.source.len;
}

pub fn peek(self: *const Scanner, bytes_ahead: usize) ?u8 {
    const offset = self.pos.offset + bytes_ahead;
    return if (offset >= self.source.len) null else self.source[offset];
}

pub fn eat(self: *Scanner) ?u8 {
    if (self.eof()) return null;
    const char = self.source[self.pos.offset];
    self.pos.offset += 1;
    if (char == '\n') {
        self.pos.line += 1;
        self.pos.column = 1;
    } else {
        self.pos.column += 1;
    }
    return char;
}

pub fn consume(self: *Scanner, comptime expected: []const u8) Error!void {
    comptime assert(expected.len > 0);
    if (self.eof()) return self.fail("unexpected EOF while looking for \"{}\"", .{fmtEscapes(expected)});
    if (self.maybeConsume(expected)) return;
    const actual = self.nextSlice(expected.len);
    return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(expected), fmtEscapes(actual) });
}

pub fn consumeFixed(self: *Scanner, byte_count: usize) Error!Span {
    assert(byte_count > 0);
    const start = self.pos;
    for (0..byte_count) |_|
        _ = self.eat() orelse return self.fail("unexpected EOF", .{});
    return self.makeSpan(start, self.pos);
}

pub fn consumeUntil(self: *Scanner, end: u8) Error!Span {
    const start = self.pos;
    var prev_pos = self.pos;
    while (self.eat()) |char| {
        if (char == end) return self.makeSpan(start, prev_pos);
        prev_pos = self.pos;
    }
    return self.fail("unexpected EOF looking for \"{}\"", .{fmtEscapes(&[_]u8{end})});
}

pub fn consumeOneOf(
    self: *Scanner,
    comptime alternatives: anytype,
) Error!std.meta.FieldEnum(@TypeOf(alternatives)) {
    comptime var message: []const u8 = "expected one of: ";
    inline for (0.., @typeInfo(@TypeOf(alternatives)).Struct.fields) |i, field| {
        const value = @field(alternatives, field.name);
        message = message ++ std.fmt.comptimePrint(
            "{s}\"{}\"",
            .{ if (i == 0) "" else ", ", comptime fmtEscapes(value) },
        );
        if (self.maybeConsume(value))
            return @intToEnum(std.meta.FieldEnum(@TypeOf(alternatives)), i);
    }
    return self.fail("{s}", .{message});
}

pub fn maybeConsume(self: *Scanner, comptime expected: []const u8) bool {
    if (!std.mem.eql(u8, self.nextSlice(expected.len), expected)) return false;
    self.pos.offset += @intCast(u32, expected.len);
    self.pos.line += @intCast(u16, comptime std.mem.count(u8, expected, "\n"));
    self.pos.column = if (comptime std.mem.lastIndexOfScalar(u8, expected, '\n')) |idx|
        expected.len - idx
    else
        self.pos.column + @intCast(u16, expected.len);
    return true;
}

pub fn skipWhitespace(self: *Scanner) void {
    while (self.peek(0)) |char| {
        switch (char) {
            ' ', '\t', '\n' => {},
            else => break,
        }
        _ = self.eat();
    }
}

pub fn fail(self: *Scanner, comptime format: []const u8, args: anytype) Error {
    return self.failAt(self.pos, format, args);
}

pub fn failOn(self: *Scanner, span: Span, comptime format: []const u8, args: anytype) Error {
    return self.failAt(span.pos, "\"{s}\": " ++ format, .{span.text} ++ args);
}

pub fn failAt(self: *Scanner, pos: Position, comptime format: []const u8, args: anytype) Error {
    const full_format = "{s}:{}:{}: " ++ format;
    const full_args = .{ self.filename, pos.line, pos.column } ++ args;
    if (@inComptime())
        @compileError(std.fmt.comptimePrint(full_format, full_args));
    self.error_message = try std.fmt.allocPrint(self.allocator.?, full_format, full_args);
    if (self.log_error) std.log.err("{s}", .{self.error_message.?});
    return error.ScanError;
}

pub fn makeSpan(self: *const Scanner, start: Position, end: Position) Span {
    return Span{ .pos = start, .text = self.source[start.offset..end.offset] };
}

fn nextSlice(self: *const Scanner, length: usize) []const u8 {
    const offset = self.pos.offset;
    return self.source[offset..std.math.min(offset + length, self.source.len)];
}

test "empty input" {
    var scanner = init(testing.allocator, "");
    defer scanner.deinit();
    try testing.expect(scanner.eof());
    try testing.expectEqual(@as(?u8, null), scanner.eat());
}

test "single character" {
    var scanner = init(testing.allocator, "x");
    defer scanner.deinit();
    try testing.expect(!scanner.eof());
    try testing.expectEqual(@as(?u8, 'x'), scanner.eat());
    try testing.expect(scanner.eof());
}

test "peek" {
    var scanner = init(testing.allocator, "ab");
    defer scanner.deinit();
    try testing.expectEqual(@as(?u8, 'a'), scanner.peek(0));
    try testing.expectEqual(@as(?u8, 'b'), scanner.peek(1));
    try testing.expectEqual(@as(?u8, null), scanner.peek(2));
    _ = scanner.eat();
    try testing.expectEqual(@as(?u8, 'b'), scanner.peek(0));
    try testing.expectEqual(@as(?u8, null), scanner.peek(1));
    try testing.expectEqual(@as(?u8, null), scanner.peek(2));
}

test "consume" {
    var scanner = init(testing.allocator, "abc");
    defer scanner.deinit();
    try testing.expectError(@as(Error, error.ScanError), scanner.consume("xyz"));
    try scanner.consume("abc");
    try testing.expect(scanner.eof());
}

test "consumeFixed" {
    var scanner = init(testing.allocator, "abc");
    defer scanner.deinit();
    try testing.expectEqualDeep(Span{
        .pos = Position{ .offset = 0, .line = 1, .column = 1 },
        .text = "ab",
    }, try scanner.consumeFixed(2));
    try testing.expectEqualDeep(Span{
        .pos = Position{ .offset = 2, .line = 1, .column = 3 },
        .text = "c",
    }, try scanner.consumeFixed(1));
    try testing.expect(scanner.eof());
}

test "consumeUntil" {
    var scanner = init(testing.allocator, "one\ntwo\n");
    defer scanner.deinit();
    try testing.expectEqualDeep(Span{
        .pos = Position{ .offset = 0, .line = 1, .column = 1 },
        .text = "one",
    }, try scanner.consumeUntil('\n'));
    try testing.expectEqualDeep(Span{
        .pos = Position{ .offset = 4, .line = 2, .column = 1 },
        .text = "two",
    }, try scanner.consumeUntil('\n'));
    try testing.expect(scanner.eof());
}

test "consumeOneOf" {
    var scanner = init(testing.allocator, "abcxyz123");
    defer scanner.deinit();
    const alternatives = .{ .abc = "abc", .xyz = "xyz" };
    const Alternative = std.meta.FieldEnum(@TypeOf(alternatives));
    try testing.expectEqual(Alternative.abc, try scanner.consumeOneOf(alternatives));
    try testing.expectEqual(Alternative.xyz, try scanner.consumeOneOf(alternatives));
    try testing.expectError(@as(Error, error.ScanError), scanner.consumeOneOf(alternatives));
    try testing.expectEqualStrings("<input>:1:7: expected one of: \"abc\", \"xyz\"", scanner.error_message.?);
}

test "maybeConsume" {
    var scanner = init(testing.allocator, "abc");
    defer scanner.deinit();
    try testing.expect(!scanner.maybeConsume("x"));
    try testing.expect(scanner.maybeConsume("a"));
    try testing.expect(!scanner.maybeConsume("a"));
    try testing.expect(scanner.maybeConsume("bc"));
    try testing.expect(scanner.eof());
}

test "skipWhitespace" {
    var scanner = init(testing.allocator, " a\n\t b");
    defer scanner.deinit();
    scanner.skipWhitespace();
    try testing.expectEqual(@as(?u8, 'a'), scanner.eat());
    scanner.skipWhitespace();
    try testing.expectEqual(@as(?u8, 'b'), scanner.eat());
    try testing.expect(scanner.eof());
    scanner.skipWhitespace();
    try testing.expect(scanner.eof());
}

test "fail" {
    var scanner = init(testing.allocator, "foo\nbar.\n");
    defer scanner.deinit();
    scanner.filename = "test.txt";
    _ = try scanner.consumeUntil('.');
    try testing.expectEqual(@as(Error, error.ScanError), scanner.fail("oops: {}", .{123}));
    try testing.expectEqualStrings("test.txt:2:5: oops: 123", scanner.error_message.?);
}

test "failOn" {
    var scanner = init(testing.allocator, "foo\nbar.\n");
    defer scanner.deinit();
    scanner.filename = "test.txt";
    _ = try scanner.consumeUntil('\n');
    const span = try scanner.consumeUntil('.');
    try testing.expectEqual(@as(Error, error.ScanError), scanner.failOn(span, "oops: {}", .{123}));
    try testing.expectEqualStrings("test.txt:2:1: \"bar\": oops: 123", scanner.error_message.?);
}
