// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements text scanning from a buffer (not a generic reader).
//! It provides functionality useful for building tokenizers and parsers.
//! The "consume" methods advance unless returning false, null, empty, or zero.
//! The "skip" methods are like "consume" but return void.
//! The "expect" methods are like "consume" but report an error on failure.
//! The "until" methods advance past the delimiter but exclude it from the result.
//! The "stop" methods are like "until" but don't advance past the delimiter.

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

pub fn uneat(self: *Scanner) void {
    self.offset -= 1;
}

pub fn prev(self: Scanner, count: usize) ?u8 {
    return if (count >= self.offset) null else self.source[self.offset - count - 1];
}

pub fn peekEol(self: *Scanner) bool {
    const char = self.peek();
    return char == null or char == '\n';
}

pub fn consume(self: *Scanner, char: u8) bool {
    if (self.peek() == char) {
        self.eat();
        return true;
    }
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

pub fn consumeAny(self: *Scanner, chars: []const u8) ?u8 {
    const c = self.peek() orelse return null;
    _ = mem.indexOfScalar(u8, chars, c) orelse return null;
    self.eat();
    return c;
}

pub fn consumeLength(self: *Scanner, length: usize) ?[]const u8 {
    const end = self.offset + length;
    if (end > self.source.len) return null;
    defer self.offset = end;
    return self.source[self.offset..end];
}

pub fn consumeLineUntil(self: *Scanner, delimiter: u8) ?[]const u8 {
    const start = self.offset;
    while (self.next()) |c| {
        if (c == delimiter) return self.source[start .. self.offset - 1];
        if (c == '\n') break;
    }
    self.offset = start;
    return null;
}

pub fn consumeStopString(self: *Scanner, delimiter: []const u8) ?[]const u8 {
    const end = mem.indexOfPos(u8, self.source, self.offset, delimiter) orelse return null;
    defer self.offset = end;
    return self.source[self.offset..end];
}

pub fn consumeStopAny(self: *Scanner, delimiters: []const u8) ?[]const u8 {
    const end = mem.indexOfAnyPos(u8, self.source, self.offset, delimiters) orelse return null;
    defer self.offset = end;
    return self.source[self.offset..end];
}

pub fn consumeRest(self: *Scanner) []const u8 {
    defer self.offset = self.source.len;
    return self.source[self.offset..];
}

pub fn consumeUntilEol(self: *Scanner) []const u8 {
    const start = self.offset;
    while (self.next()) |c| if (c == '\n') return self.source[start .. self.offset - 1];
    return self.source[start..self.offset];
}

pub fn consumeWhileAny(self: *Scanner, chars: []const u8) []const u8 {
    const end = mem.indexOfNonePos(u8, self.source, self.offset, chars) orelse self.source.len;
    defer self.offset = end;
    return self.source[self.offset..end];
}

pub fn consumeMany(self: *Scanner, char: u8) usize {
    const start = self.offset;
    while (self.peek()) |c| if (c == char) self.eat() else break;
    return self.offset - start;
}

pub fn skip(self: *Scanner, char: u8) void {
    _ = self.consume(char);
}

pub fn skipMany(self: *Scanner, char: u8) void {
    _ = self.consumeMany(char);
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

    // uneat
    {
        var scanner = Scanner{ .source = "xy", .reporter = &reporter };
        scanner.eat();
        scanner.uneat();
        try testing.expectEqual(@as(?u8, 'x'), scanner.peek());
    }

    // eof is sticky
    {
        var scanner = Scanner{ .source = "", .reporter = &reporter };
        try testing.expect(scanner.eof());
        try testing.expect(scanner.eof());
        try testing.expectEqual(@as(?u8, null), scanner.peek());
        try testing.expectEqual(@as(?u8, null), scanner.peek());
        try testing.expectEqual(@as(?u8, null), scanner.next());
        try testing.expectEqual(@as(?u8, null), scanner.next());
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

    // peekEol
    {
        var scanner = Scanner{ .source = "x\n", .reporter = &reporter };
        try testing.expect(!scanner.peekEol());
        scanner.eat();
        try testing.expect(scanner.peekEol());
        try testing.expect(!scanner.eof());
        scanner.eat();
        try testing.expect(scanner.peekEol());
        try testing.expect(scanner.eof());
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

    // consumeAny
    {
        var scanner = Scanner{ .source = "foo", .reporter = &reporter };
        try testing.expectEqual(@as(?u8, null), scanner.consumeAny("ab"));
        try testing.expectEqual(@as(?u8, 'f'), scanner.consumeAny("af"));
        try testing.expectEqual(@as(?u8, null), scanner.consumeAny("af"));
        try testing.expectEqual(@as(?u8, 'o'), scanner.consumeAny("o"));
        try testing.expectEqual(@as(?u8, 'o'), scanner.consumeAny("...o..."));
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

    // consumeStopString
    {
        var scanner = Scanner{ .source = "this and that.", .reporter = &reporter };
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeStopString("---"));
        try testing.expectEqualStrings("", scanner.consumeStopString("").?);
        try testing.expectEqualStrings("this", scanner.consumeStopString(" and ").?);
        try testing.expectEqualStrings("", scanner.consumeStopString(" and ").?);
        try scanner.expectString(" and ");
        try testing.expectEqualStrings("that", scanner.consumeStopString(".").?);
        try testing.expectEqualStrings("", scanner.consumeStopString(".").?);
        try testing.expect(scanner.consume('.'));
        try testing.expect(scanner.eof());
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeStopString("x"));
        try testing.expectEqualStrings("", scanner.consumeStopString("").?);
    }

    // consumeStopAny
    {
        var scanner = Scanner{ .source = "foo.bar\nbaz", .reporter = &reporter };
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeStopAny(""));
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeStopAny("!"));
        try testing.expectEqualStrings("foo", scanner.consumeStopAny("\n.").?);
        try testing.expectEqualStrings("", scanner.consumeStopAny("\n.").?);
        try testing.expect(scanner.consume('.'));
        try testing.expectEqualStrings("bar", scanner.consumeStopAny("\n.").?);
        try testing.expectEqualStrings("", scanner.consumeStopAny("\n.").?);
        try testing.expect(scanner.consume('\n'));
        try testing.expectEqual(@as(?[]const u8, null), scanner.consumeStopAny("\n."));
    }

    // consumeRest
    {
        var scanner = Scanner{ .source = "foo\nbar", .reporter = &reporter };
        try testing.expect(scanner.consume('f'));
        try testing.expectEqualStrings("oo\nbar", scanner.consumeRest());
        try testing.expect(scanner.eof());
        try testing.expectEqualStrings("", scanner.consumeRest());
        try testing.expect(scanner.eof());
    }

    // consumeUntilEol
    {
        var scanner = Scanner{ .source = "foo\nbar", .reporter = &reporter };
        try testing.expectEqualStrings("foo", scanner.consumeUntilEol());
        try testing.expectEqualStrings("bar", scanner.consumeUntilEol());
        try testing.expect(scanner.eof());
    }

    // consumeWhileAny
    {
        var scanner = Scanner{ .source = "foo\nbar", .reporter = &reporter };
        try testing.expectEqualStrings("", scanner.consumeWhileAny(""));
        try testing.expectEqualStrings("", scanner.consumeWhileAny("x"));
        try testing.expectEqualStrings("f", scanner.consumeWhileAny("f"));
        try testing.expectEqualStrings("oo\nb", scanner.consumeWhileAny("bo\n"));
        try testing.expectEqualStrings("ar", scanner.consumeWhileAny("xar"));
        try testing.expectEqualStrings("", scanner.consumeWhileAny("abc"));
        try testing.expect(scanner.eof());
    }

    // consumeMany
    {
        var scanner = Scanner{ .source = "abbccc", .reporter = &reporter };
        try testing.expectEqual(@as(usize, 1), scanner.consumeMany('a'));
        try testing.expectEqual(@as(usize, 0), scanner.consumeMany('a'));
        try testing.expectEqual(@as(usize, 2), scanner.consumeMany('b'));
        try testing.expectEqual(@as(usize, 0), scanner.consumeMany('b'));
        try testing.expectEqual(@as(usize, 3), scanner.consumeMany('c'));
        try testing.expectEqual(@as(usize, 0), scanner.consumeMany('c'));
        try testing.expect(scanner.eof());
    }

    // skip
    {
        var scanner = Scanner{ .source = "x", .reporter = &reporter };
        scanner.skip('y');
        try testing.expect(!scanner.eof());
        scanner.skip('x');
        try testing.expect(scanner.eof());
    }

    // skipMany
    {
        var scanner = Scanner{ .source = "abb", .reporter = &reporter };
        scanner.skipMany('b');
        scanner.skipMany('a');
        scanner.skipMany('b');
        try testing.expect(scanner.eof());
    }

    // expect
    {
        var scanner = Scanner{ .source = "ab", .reporter = &reporter };
        try scanner.expect('a');
        try reporter.expectFailure("<input>:1:2: expected \"a\", got \"b\"", scanner.expect('a'));
        try scanner.expect('b');
        try reporter.expectFailure("<input>:1:3: expected \"b\", got EOF", scanner.expect('b'));
    }

    // expectString
    {
        var scanner = Scanner{ .source = "foo bar", .reporter = &reporter };
        try scanner.expectString("foo ");
        try reporter.expectFailure("<input>:1:5: expected \"barn\", got \"bar\"", scanner.expectString("barn"));
        try scanner.expectString("bar");
        try reporter.expectFailure("<input>:1:8: expected \"qux\", got EOF", scanner.expectString("qux"));
    }

    // fail
    {
        var scanner = Scanner{ .source = "\n", .reporter = &reporter };
        scanner.eat();
        try reporter.expectFailure("<input>:2:1: msg: arg", @as(Error!void, scanner.fail("msg: {s}", .{"arg"})));
    }

    // failOn
    {
        var scanner = Scanner{ .source = "foo bar", .reporter = &reporter };
        try reporter.expectFailure("<input>:1:5: \"bar\": bad", @as(Error!void, scanner.failOn(scanner.source[4..], "bad", .{})));
    }

    // failAtOffset
    {
        var scanner = Scanner{ .source = "foo bar", .reporter = &reporter };
        try reporter.expectFailure("<input>:1:5: bad", @as(Error!void, scanner.failAtOffset(4, "bad", .{})));
    }

    // failAtOffset
    {
        var scanner = Scanner{ .source = "foo bar", .reporter = &reporter };
        try reporter.expectFailure("<input>:1:5: bad", @as(Error!void, scanner.failAtPtr(scanner.source.ptr + 4, "bad", .{})));
    }
}
