// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements text scanning from a buffer (not a generic reader).
//! It provides primitives useful for building tokenizers and parsers.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const fmtEscapes = std.zig.fmtEscapes;
const Reporter = @import("Reporter.zig");
const Error = Reporter.Error;
const Location = Reporter.Location;
const Scanner = @This();

source: []const u8,
reporter: *Reporter,
filename: []const u8 = "<input>",
offset: usize = 0,

pub fn eof(self: Scanner) bool {
    return self.offset == self.source.len;
}

pub fn next(self: *Scanner) ?u8 {
    if (self.eof()) return null;
    const char = self.source[self.offset];
    self.offset += 1;
    return char;
}

pub fn peek(self: Scanner) ?u8 {
    return if (self.eof()) null else self.source[self.offset];
}

pub fn inc(self: *Scanner) void {
    assert(self.offset < self.source.len);
    self.offset += 1;
}

pub fn prev(self: Scanner, count: usize) ?u8 {
    return if (count >= self.offset) null else self.source[self.offset - count - 1];
}

pub fn eat(self: *Scanner, char: u8) bool {
    if (self.peek()) |c| if (c == char) {
        self.inc();
        return true;
    };
    return false;
}

pub fn eatString(self: *Scanner, string: []const u8) bool {
    const end = self.offset + string.len;
    if (end > self.source.len) return false;
    if (!mem.eql(u8, self.source[self.offset..end], string)) return false;
    self.offset += string.len;
    return true;
}

pub fn expect(self: *Scanner, char: u8) Error!void {
    const actual = self.peek() orelse return self.fail("expected \"{}\", got EOF", .{fmtEscapes(&.{char})});
    if (actual != char) return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(&.{char}), fmtEscapes(&.{actual}) });
    self.inc();
}

pub fn expectString(self: *Scanner, string: []const u8) Error!void {
    if (self.eatString(string)) return;
    if (self.eof()) return self.fail("expected \"{}\", got EOF", .{fmtEscapes(string)});
    const actual = self.source[self.offset..@min(self.offset + string.len, self.source.len)];
    return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(string), fmtEscapes(actual) });
}

// TODO revisit, also test
pub fn eatWhile(self: *Scanner, char: u8) usize {
    const start = self.offset;
    while (self.peek()) |c| if (c == char) self.inc() else break;
    return self.offset - start;
}

pub fn eatUntil(self: *Scanner, char: u8) bool {
    while (self.next()) |c| if (c == char) return true;
    return false;
}

// TODO revisit, also test
pub fn eatIfLine(self: *Scanner, line: []const u8) bool {
    const end = self.offset + line.len;
    if (end > self.source.len) return false;
    if (!mem.eql(u8, self.source[self.offset..end], line)) return false;
    if (end == self.source.len) {
        self.offset += line.len;
        return true;
    }
    if (self.source[end] != '\n') return false;
    self.offset += line.len + 1;
    return true;
}

pub fn consumeFixed(self: *Scanner, byte_count: usize) Error![]const u8 {
    assert(byte_count > 0); // TODO remove?
    const start = self.offset;
    if (start + byte_count > self.source.len) return self.fail("unexpected EOF", .{});
    self.offset += byte_count;
    return self.source[start..self.offset];
}

pub fn untilStringOrEof(self: *Scanner, string: []const u8) []const u8 {
    const start = self.offset;
    const end = std.mem.indexOfPos(u8, self.source, self.offset, string) orelse self.source.len;
    self.offset = end;
    return self.source[start..end];
}

pub fn skipReverse(self: *Scanner, char: u8, stop: usize) void {
    while (self.offset > stop and self.source[self.offset - 1] == char) self.offset -= 1;
}

pub fn untilReverse(self: *Scanner, char: u8, stop: usize) bool {
    while (self.offset > stop) {
        self.offset -= 1;
        if (self.source[self.offset] == char) return true;
    }
    return false;
}

pub fn untilOnLine(self: *Scanner, char: u8) ?[]const u8 {
    const start = self.offset;
    while (self.next()) |ch| {
        if (ch == char) return self.source[start .. self.offset - 1];
        if (ch == '\n') break;
    }
    self.offset = start;
    return null;
}

pub fn restOfLine(self: *Scanner) []const u8 {
    const start = self.offset;
    while (self.next()) |ch| if (ch == '\n') return self.source[start .. self.offset - 1];
    return self.source[start..self.offset];
}

fn slice(self: Scanner, length: usize) []const u8 {
    const offset = self.offset;
    return self.source[offset..@min(offset + length, self.source.len)];
}

pub fn until(self: *Scanner, end: u8) Error![]const u8 {
    const start = self.offset;
    while (self.next()) |char| if (char == end) return self.source[start .. self.offset - 1];
    return self.fail("unexpected EOF while looking for \"{}\"", .{fmtEscapes(&.{end})});
}

pub fn choice(
    self: *Scanner,
    comptime alternatives: anytype,
) Error!std.meta.FieldEnum(@TypeOf(alternatives)) {
    comptime var message: []const u8 = "expected";
    comptime var max_length = 0;
    const fields = @typeInfo(@TypeOf(alternatives)).Struct.fields;
    comptime assert(fields.len > 0);
    inline for (fields, 0..) |field, i| {
        const value = @field(alternatives, field.name);
        if (self.eatString(value)) return @enumFromInt(i);
        const comma = if (i == 0 or fields.len == 2) "" else ",";
        const space = if (i == fields.len - 1) " or " else " ";
        message = message ++ std.fmt.comptimePrint(
            "{s}{s}\"{}\"",
            .{ comma, space, comptime fmtEscapes(value) },
        );
        max_length = @max(max_length, value.len);
    }
    return self.fail("{s}, got \"{s}\"", .{ message, self.slice(max_length) });
}

pub fn skipWhitespace(self: *Scanner) void {
    while (self.peek()) |char| switch (char) {
        ' ', '\t', '\n' => self.inc(),
        else => break,
    };
}

pub fn fail(self: *Scanner, comptime format: []const u8, args: anytype) Error {
    return self.failAtOffset(self.offset, format, args);
}

pub fn failOn(self: *Scanner, token: []const u8, comptime format: []const u8, args: anytype) Error {
    return self.failAtPtr(token.ptr, "\"{}\": " ++ format, .{fmtEscapes(token)} ++ args);
}

pub fn failAtOffset(self: *Scanner, offset: usize, comptime format: []const u8, args: anytype) Error {
    return self.reporter.failAt(self.filename, Location.fromOffset(self.source, offset), format, args);
}

pub fn failAtPtr(self: *Scanner, ptr: [*]const u8, comptime format: []const u8, args: anytype) Error {
    return self.reporter.failAt(self.filename, Location.fromPtr(self.source, ptr), format, args);
}

test "empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "", .reporter = &reporter };
    try testing.expect(scanner.eof());
    try testing.expectEqual(@as(?u8, null), scanner.next());
}

test "single character" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "x", .reporter = &reporter };
    try testing.expect(!scanner.eof());
    try testing.expectEqual(@as(?u8, 'x'), scanner.next());
    try testing.expect(scanner.eof());
    try testing.expectEqual(@as(?u8, null), scanner.next());
}

// TODO consider doing `test peek { ... }` instead of `test "peek" { ... }`
test "peek" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "ab", .reporter = &reporter };
    try testing.expectEqual(@as(?u8, 'a'), scanner.peek());
    scanner.inc();
    try testing.expectEqual(@as(?u8, 'b'), scanner.peek());
}

test "consume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "a\nbc", .reporter = &reporter };
    try testing.expectEqualStrings("a\nb", try scanner.consumeFixed(3));
    try testing.expectEqualStrings("c", try scanner.consumeFixed(1));
    try testing.expect(scanner.eof());
}

test "eatIfString" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "abc", .reporter = &reporter };
    try testing.expect(!scanner.eatString("x"));
    try testing.expect(scanner.eatString("a"));
    try testing.expect(!scanner.eatString("a"));
    try testing.expect(scanner.eatString("bc"));
    try testing.expect(scanner.eof());
}

test "expect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "abc", .reporter = &reporter };
    try reporter.expectFailure(
        \\<input>:1:1: expected "xyz", got "abc"
    , scanner.expectString("xyz"));
    try scanner.expectString("abc");
    try testing.expect(scanner.eof());
}

test "until" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "one\ntwo\n", .reporter = &reporter };
    try testing.expectEqualStrings("one", try scanner.until('\n'));
    try testing.expectEqualStrings("two", try scanner.until('\n'));
    try testing.expect(scanner.eof());
}

test "choice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "abcxyz123", .reporter = &reporter };
    const alternatives = .{ .abc = "abc", .xyz = "xyz" };
    const Alternative = std.meta.FieldEnum(@TypeOf(alternatives));
    try testing.expectEqual(Alternative.abc, try scanner.choice(alternatives));
    try testing.expectEqual(Alternative.xyz, try scanner.choice(alternatives));
    try reporter.expectFailure(
        \\<input>:1:7: expected "abc" or "xyz", got "123"
    , scanner.choice(alternatives));
}

test "skipWhitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = " a\n\t b", .reporter = &reporter };
    scanner.skipWhitespace();
    try testing.expectEqual(@as(?u8, 'a'), scanner.next());
    scanner.skipWhitespace();
    try testing.expectEqual(@as(?u8, 'b'), scanner.next());
    try testing.expect(scanner.eof());
    scanner.skipWhitespace();
    try testing.expect(scanner.eof());
}

// TODO: test rest of stuff
