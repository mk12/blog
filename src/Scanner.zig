// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements text scanning from a buffer (not a generic reader).
//! It provides functionality useful for building tokenizers and parsers.
//! Calling next() advances through the characters, and returns null on EOF.
//! It is equivalent to peek() followed by eat().
//! The "consume" methods advance unless returning false, null, empty, or zero.
//! The "expect" methods report an error on failure.
//! The "until" methods advance past the delimiter but exclude it from the result.

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
    defer self.offset += 1;
    return self.source[self.offset];
}

pub fn peek(self: Scanner) ?u8 {
    return if (self.eof()) null else self.source[self.offset];
}

pub fn eat(self: *Scanner) void {
    assert(self.offset < self.source.len);
    self.offset += 1;
}

pub fn prev(self: Scanner, count: usize) ?u8 {
    return if (count >= self.offset) null else self.source[self.offset - count - 1];
}

pub fn consume(self: *Scanner, char: u8) bool {
    if (self.peek()) |c| if (c == char) {
        self.eat();
        return true;
    };
    return false;
}

pub fn consumeString(self: *Scanner, string: []const u8) bool {
    const end = self.offset + string.len;
    if (end > self.source.len) return false;
    if (!mem.eql(u8, self.source[self.offset..end], string)) return false;
    self.offset += string.len;
    return true;
}

pub fn consumeStringEol(self: *Scanner, string: []const u8) bool {
    if (!self.consumeString(string)) return false;
    _ = self.consume('\n');
    return true;
}

pub fn consumeLength(self: *Scanner, length: usize) ?[]const u8 {
    const end = self.offset + length;
    if (end > self.source.len) return null;
    defer self.offset = end;
    return self.source[self.offset..end];
}

pub fn consumeUntil(self: *Scanner, delimiter: u8) ?[]const u8 {
    const start = self.offset;
    while (self.next()) |char| if (char == delimiter) return self.source[start .. self.offset - 1];
    return null;
}

pub fn consumeUntilNoEol(self: *Scanner, delimiter: u8) ?[]const u8 {
    const start = self.offset;
    while (self.next()) |char| {
        if (char == delimiter) return self.source[start .. self.offset - 1];
        if (char == '\n') break;
    }
    self.offset = start;
    return null;
}

pub fn consumeUntilEol(self: *Scanner) []const u8 {
    const start = self.offset;
    while (self.next()) |ch| if (ch == '\n') return self.source[start .. self.offset - 1];
    return self.source[start..self.offset];
}

pub fn consumeUntilStringOrEof(self: *Scanner, string: []const u8) []const u8 {
    const end = std.mem.indexOfPos(u8, self.source, self.offset, string) orelse self.source.len;
    defer self.offset = end;
    return self.source[self.offset..end];
}

pub fn consumeWhile(self: *Scanner, char: u8) usize {
    const start = self.offset;
    while (self.peek()) |c| if (c == char) self.eat() else break;
    return self.offset - start;
}

pub fn skipWhile(self: *Scanner, char: u8) void {
    _ = self.consumeWhile(char);
}

pub fn expect(self: *Scanner, char: u8) Error!void {
    if (self.consume(char)) return;
    const actual = self.peek() orelse return self.fail("expected \"{}\", got EOF", .{fmtEscapes(&.{char})});
    return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(&.{char}), fmtEscapes(&.{actual}) });
}

pub fn expectString(self: *Scanner, string: []const u8) Error!void {
    if (self.consumeString(string)) return;
    if (self.eof()) return self.fail("expected \"{}\", got EOF", .{fmtEscapes(string)});
    const actual = self.source[self.offset..@min(self.offset + string.len, self.source.len)];
    return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(string), fmtEscapes(actual) });
}

pub fn expectUntil(self: *Scanner, delimiter: u8) Error![]const u8 {
    return self.consumeUntil(delimiter) orelse
        self.fail("unexpected EOF while looking for \"{}\"", .{fmtEscapes(&.{delimiter})});
}

//TODO
pub fn skipReverse(self: *Scanner, char: u8, stop: usize) void {
    while (self.offset > stop and self.source[self.offset - 1] == char) self.offset -= 1;
}

//TODO
pub fn untilReverse(self: *Scanner, char: u8, stop: usize) bool {
    while (self.offset > stop) {
        self.offset -= 1;
        if (self.source[self.offset] == char) return true;
    }
    return false;
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
    scanner.eat();
    try testing.expectEqual(@as(?u8, 'b'), scanner.peek());
}

test "consume" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "a\nbc", .reporter = &reporter };
    try testing.expectEqualStrings("a\nb", scanner.consumeLength(3).?);
    try testing.expectEqualStrings("c", scanner.consumeLength(1).?);
    try testing.expect(scanner.eof());
}

test "eatIfString" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = "abc", .reporter = &reporter };
    try testing.expect(!scanner.consumeString("x"));
    try testing.expect(scanner.consumeString("a"));
    try testing.expect(!scanner.consumeString("a"));
    try testing.expect(scanner.consumeString("bc"));
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
    try testing.expectEqualStrings("one", try scanner.expectUntil('\n'));
    try testing.expectEqualStrings("two", try scanner.expectUntil('\n'));
    try testing.expect(scanner.eof());
}

// TODO: test rest of stuff
