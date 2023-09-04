// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements text scanning from a buffer (not a generic reader).
//! It provides functionality useful for building tokenizers and parsers.
//! Calling next() advances through the characters, and returns null on EOF.
//! It is equivalent to peek() followed by eat().
//! The "consume" methods advance unless returning false, null, empty, or zero.
//! The "skip" methods are like "consume" but return void.
//! The "expect" methods are like "consume" but report an error on failure.
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
    const end = self.offset + string.len;
    if (end > self.source.len) return false;
    if (!mem.eql(u8, self.source[self.offset..end], string)) return false;
    self.offset = if (end == self.source.len) end else if (self.source[end] == '\n') end + 1 else return false;
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
    // TODO: to behave according to "consume" rule, must reset offset
    // if returning null. But expectUntil uses consumeUntil, and Metadata parsing
    // does expectUntil, and wants error message about not finding the delimiter
    // to refer to as far as it got (EOF), not to where it started looking.
    // self.offset = start;
    return null;
}

pub fn consumeLineUntil(self: *Scanner, delimiter: u8) ?[]const u8 {
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

pub fn consumeWhile(self: *Scanner, char: u8) usize {
    const start = self.offset;
    while (self.peek()) |c| if (c == char) self.eat() else break;
    return self.offset - start;
}

pub fn skip(self: *Scanner, char: u8) void {
    _ = self.consume(char);
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

// Everything is in one test block because to avoid repeating setup code.
test "everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);

    // empty input
    {
        var scanner = Scanner{ .source = "", .reporter = &reporter };
        try testing.expect(scanner.eof());
        try testing.expectEqual(@as(?u8, null), scanner.next());
    }

    // eof
    {
        var scanner = Scanner{ .source = "x", .reporter = &reporter };
        try testing.expect(!scanner.eof());
        scanner.eat();
        try testing.expect(scanner.eof());
    }

    // next
    {
        var scanner = Scanner{ .source = "x", .reporter = &reporter };
        try testing.expectEqual(@as(?u8, 'x'), scanner.next());
        try testing.expectEqual(@as(?u8, null), scanner.next());
    }

    // peek and eat
    {
        var scanner = Scanner{ .source = "xy", .reporter = &reporter };
        try testing.expectEqual(@as(?u8, 'x'), scanner.peek());
        try testing.expectEqual(@as(?u8, 'x'), scanner.peek());
        scanner.eat();
        try testing.expectEqual(@as(?u8, 'y'), scanner.peek());
    }

    // prev
    {
        var scanner = Scanner{ .source = "xy", .reporter = &reporter };
        try testing.expectEqual(@as(?u8, null), scanner.prev(0));
        scanner.eat();
        try testing.expectEqual(@as(?u8, 'x'), scanner.prev(0));
        try testing.expectEqual(@as(?u8, null), scanner.prev(1));
        scanner.eat();
        try testing.expectEqual(@as(?u8, 'y'), scanner.prev(0));
        try testing.expectEqual(@as(?u8, 'x'), scanner.prev(1));
    }

    // consume
    {
        var scanner = Scanner{ .source = "xy", .reporter = &reporter };
        try testing.expect(scanner.consume('x'));
        try testing.expect(!scanner.consume('x'));
        try testing.expect(scanner.consume('y'));
        try testing.expect(scanner.eof());
    }

    // consumeString
    {
        var scanner = Scanner{ .source = "foo", .reporter = &reporter };
        try testing.expect(!scanner.consumeString("fox"));
        try testing.expect(scanner.consumeString("foo"));
        try testing.expect(scanner.eof());
    }

    // consumeStringEol
    {
        var scanner = Scanner{ .source = "foo\nbar", .reporter = &reporter };
        try testing.expect(!scanner.consumeStringEol("fo"));
        try testing.expect(scanner.consumeStringEol("foo"));
        try testing.expect(!scanner.consumeStringEol("ba"));
        try testing.expect(scanner.consumeStringEol("bar"));
        try testing.expect(scanner.eof());
    }

    // consumeLength
    {
        var scanner = Scanner{ .source = "foo bar", .reporter = &reporter };
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeLength(8));
        try testing.expectEqualStrings("foo", scanner.consumeLength(3).?);
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeLength(5));
        try testing.expectEqualStrings(" ", scanner.consumeLength(1).?);
        try testing.expectEqualStrings("bar", scanner.consumeLength(3).?);
        try testing.expect(scanner.eof());
    }

    // consumeUntil
    // {
    //     var scanner = Scanner{ .source = "foo bar", .reporter = &reporter };
    //     try testing.expectEqual(@as(?[]const u8, null), scanner.consumeUntil('.'));
    //     try testing.expectEqualStrings("foo", scanner.consumeUntil(' ').?);
    //     try testing.expectEqual(@as(?[]const u8, null), scanner.consumeUntil('f'));
    //     try testing.expectEqualStrings("ba", scanner.consumeUntil('r').?);
    //     try testing.expect(scanner.eof());
    // }

    // consumeLineUntil
    {
        var scanner = Scanner{ .source = "foo:\nbar.", .reporter = &reporter };
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeLineUntil('.'));
        try testing.expectEqualStrings("foo", scanner.consumeLineUntil(':').?);
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeLineUntil('.'));
        try testing.expectEqual(@as(?u8, '\n'), scanner.next());
        try testing.expectEqualStrings("bar", scanner.consumeLineUntil('.').?);
        try testing.expect(scanner.eof());
    }
}

// test "single character" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var reporter = Reporter.init(arena.allocator());
//     errdefer |err| reporter.showMessage(err);
//     var scanner = Scanner{ .source = "x", .reporter = &reporter };
//     try testing.expect(!scanner.eof());
//     try testing.expectEqual(@as(?u8, 'x'), scanner.next());
//     try testing.expect(scanner.eof());
//     try testing.expectEqual(@as(?u8, null), scanner.next());
// }

// // TODO consider doing `test peek { ... }` instead of `test "peek" { ... }`
// test "peek" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var reporter = Reporter.init(arena.allocator());
//     errdefer |err| reporter.showMessage(err);
//     var scanner = Scanner{ .source = "ab", .reporter = &reporter };
//     try testing.expectEqual(@as(?u8, 'a'), scanner.peek());
//     scanner.eat();
//     try testing.expectEqual(@as(?u8, 'b'), scanner.peek());
// }

// test "consume" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var reporter = Reporter.init(arena.allocator());
//     errdefer |err| reporter.showMessage(err);
//     var scanner = Scanner{ .source = "a\nbc", .reporter = &reporter };
//     try testing.expectEqualStrings("a\nb", scanner.consumeLength(3).?);
//     try testing.expectEqualStrings("c", scanner.consumeLength(1).?);
//     try testing.expect(scanner.eof());
// }

// test "eatIfString" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var reporter = Reporter.init(arena.allocator());
//     errdefer |err| reporter.showMessage(err);
//     var scanner = Scanner{ .source = "abc", .reporter = &reporter };
//     try testing.expect(!scanner.consumeString("x"));
//     try testing.expect(scanner.consumeString("a"));
//     try testing.expect(!scanner.consumeString("a"));
//     try testing.expect(scanner.consumeString("bc"));
//     try testing.expect(scanner.eof());
// }

// test "expect" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var reporter = Reporter.init(arena.allocator());
//     errdefer |err| reporter.showMessage(err);
//     var scanner = Scanner{ .source = "abc", .reporter = &reporter };
//     try reporter.expectFailure(
//         \\<input>:1:1: expected "xyz", got "abc"
//     , scanner.expectString("xyz"));
//     try scanner.expectString("abc");
//     try testing.expect(scanner.eof());
// }

// test "until" {
//     var arena = std.heap.ArenaAllocator.init(testing.allocator);
//     defer arena.deinit();
//     var reporter = Reporter.init(arena.allocator());
//     errdefer |err| reporter.showMessage(err);
//     var scanner = Scanner{ .source = "one\ntwo\n", .reporter = &reporter };
//     try testing.expectEqualStrings("one", try scanner.expectUntil('\n'));
//     try testing.expectEqualStrings("two", try scanner.expectUntil('\n'));
//     try testing.expect(scanner.eof());
// }

// // TODO: test rest of stuff
