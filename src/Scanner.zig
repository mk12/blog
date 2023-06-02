// Copyright 2023 Mitchell Kember. Subject to the MIT License.

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
location: Location = .{},

pub const Span = struct {
    text: []const u8,
    location: Location,
};

pub fn eof(self: Scanner) bool {
    return self.offset == self.source.len;
}

pub fn peek(self: Scanner, bytes_ahead: usize) ?u8 {
    const offset = self.offset + bytes_ahead;
    return if (offset >= self.source.len) null else self.source[offset];
}

pub fn peekSlice(self: Scanner, length: usize) []const u8 {
    const offset = self.offset;
    return self.source[offset..std.math.min(offset + length, self.source.len)];
}

pub fn next(self: *Scanner) ?u8 {
    if (self.eof()) return null;
    const char = self.source[self.offset];
    self.eat(char);
    return char;
}

pub fn eat(self: *Scanner, char: u8) void {
    self.offset += 1;
    if (char == '\n') {
        self.location.line += 1;
        self.location.column = 1;
    } else {
        self.location.column += 1;
    }
}

pub fn consume(self: *Scanner, byte_count: usize) Error!Span {
    assert(byte_count > 0);
    const location = self.location;
    const start = self.offset;
    for (0..byte_count) |_|
        _ = self.next() orelse return self.fail("unexpected EOF", .{});
    const text = self.source[start..self.offset];
    return Span{ .text = text, .location = location };
}

pub fn attempt(self: *Scanner, comptime string: []const u8) bool {
    comptime assert(string.len > 0);
    if (!mem.eql(u8, self.peekSlice(string.len), string)) return false;
    self.offset += @intCast(u32, string.len);
    self.location.line += @intCast(u16, comptime mem.count(u8, string, "\n"));
    self.location.column = if (comptime mem.lastIndexOfScalar(u8, string, '\n')) |idx|
        string.len - idx
    else
        self.location.column + @intCast(u16, string.len);
    return true;
}

pub fn expect(self: *Scanner, comptime expected: []const u8) Error!void {
    if (self.eof()) return self.fail("unexpected EOF, expected \"{}\"", .{fmtEscapes(expected)});
    if (self.attempt(expected)) return;
    const actual = self.peekSlice(expected.len);
    return self.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(expected), fmtEscapes(actual) });
}

pub fn until(self: *Scanner, end: u8) Error!Span {
    const location = self.location;
    const start = self.offset;
    while (self.next()) |char| {
        if (char == end) {
            const text = self.source[start .. self.offset - 1];
            return Span{ .text = text, .location = location };
        }
    }
    return self.fail("unexpected EOF while looking for \"{}\"", .{fmtEscapes(&.{end})});
}

pub fn choice(
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
        if (self.attempt(value))
            return @intToEnum(std.meta.FieldEnum(@TypeOf(alternatives)), i);
    }
    return self.fail("{s}", .{message});
}

pub fn skipWhitespace(self: *Scanner) void {
    while (self.peek(0)) |char| {
        switch (char) {
            ' ', '\t', '\n' => _ = self.next(),
            else => break,
        }
    }
}

pub fn fail(self: *Scanner, comptime format: []const u8, args: anytype) Error {
    return self.reporter.fail(self.filename, self.location, format, args);
}

pub fn failOn(self: *Scanner, span: Span, comptime format: []const u8, args: anytype) Error {
    return self.reporter.fail(self.filename, span.location, "\"{s}\": " ++ format, .{span.text} ++ args);
}

test "empty input" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "", .reporter = &reporter };
    try testing.expect(scanner.eof());
    try testing.expectEqual(@as(?u8, null), scanner.next());
}

test "single character" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "x", .reporter = &reporter };
    try testing.expect(!scanner.eof());
    try testing.expectEqual(@as(?u8, 'x'), scanner.next());
    try testing.expect(scanner.eof());
    try testing.expectEqual(@as(?u8, null), scanner.next());
}

test "peek" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "ab", .reporter = &reporter };
    try testing.expectEqual(@as(?u8, 'a'), scanner.peek(0));
    try testing.expectEqual(@as(?u8, 'b'), scanner.peek(1));
    try testing.expectEqual(@as(?u8, null), scanner.peek(2));
    _ = scanner.next();
    try testing.expectEqual(@as(?u8, 'b'), scanner.peek(0));
    try testing.expectEqual(@as(?u8, null), scanner.peek(1));
    try testing.expectEqual(@as(?u8, null), scanner.peek(2));
}

test "consume" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "abc", .reporter = &reporter };
    {
        const span = try scanner.consume(2);
        try testing.expectEqualStrings("ab", span.text);
        try testing.expectEqual(Location{ .line = 1, .column = 1 }, span.location);
    }
    {
        const span = try scanner.consume(1);
        try testing.expectEqualStrings("c", span.text);
        try testing.expectEqual(Location{ .line = 1, .column = 3 }, span.location);
    }
    try testing.expect(scanner.eof());
}

test "attempt" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "abc", .reporter = &reporter };
    try testing.expect(!scanner.attempt("x"));
    try testing.expect(scanner.attempt("a"));
    try testing.expect(!scanner.attempt("a"));
    try testing.expect(scanner.attempt("bc"));
    try testing.expect(scanner.eof());
}

test "expect" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "abc", .reporter = &reporter };
    try reporter.expectFailure(
        \\<input>:1:1: expected "xyz", got "abc"
    , scanner.expect("xyz"));
    try scanner.expect("abc");
    try testing.expect(scanner.eof());
}

test "until" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "one\ntwo\n", .reporter = &reporter };
    {
        const span = try scanner.until('\n');
        try testing.expectEqualStrings("one", span.text);
        try testing.expectEqual(Location{ .line = 1, .column = 1 }, span.location);
    }
    {
        const span = try scanner.until('\n');
        try testing.expectEqualStrings("two", span.text);
        try testing.expectEqual(Location{ .line = 2, .column = 1 }, span.location);
    }
    try testing.expect(scanner.eof());
}

test "choice" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = "abcxyz123", .reporter = &reporter };
    const alternatives = .{ .abc = "abc", .xyz = "xyz" };
    const Alternative = std.meta.FieldEnum(@TypeOf(alternatives));
    try testing.expectEqual(Alternative.abc, try scanner.choice(alternatives));
    try testing.expectEqual(Alternative.xyz, try scanner.choice(alternatives));
    try reporter.expectFailure(
        \\<input>:1:7: expected one of: "abc", "xyz"
    , scanner.choice(alternatives));
}

test "skipWhitespace" {
    var reporter = Reporter{};
    errdefer |err| reporter.print(err);
    var scanner = Scanner{ .source = " a\n\t b", .reporter = &reporter };
    scanner.skipWhitespace();
    try testing.expectEqual(@as(?u8, 'a'), scanner.next());
    scanner.skipWhitespace();
    try testing.expectEqual(@as(?u8, 'b'), scanner.next());
    try testing.expect(scanner.eof());
    scanner.skipWhitespace();
    try testing.expect(scanner.eof());
}

// test "fail" {
//     var log = std.ArrayList(u8).init(testing.allocator);
//     defer log.deinit();
//     const reporter = Reporter{ .filename = "test.txt", .out = &log };
//     var scanner = Scanner{ .source = "foo\nbar.\n", .reporter = reporter };
//     // Advance a bit so the error location is more interesting.
//     _ = try scanner.until('.');
//     try testing.expectEqual(
//         Error.ErrorWasReported,
//         scanner.fail("oops: {}", .{123}),
//     );
//     try testing.expectEqualStrings(
//         \\test.txt:2:5: oops: 123
//     , log.items);
// }

// test "failOn" {
//     var log = std.ArrayList(u8).init(testing.allocator);
//     defer log.deinit();
//     const reporter = Reporter{ .filename = "test.txt", .out = &log };
//     var scanner = Scanner{ .source = "foo\nbar.\n", .reporter = reporter };
//     _ = try scanner.until('\n');
//     const span = try scanner.until('.');
//     try testing.expectEqual(
//         Error.ErrorWasReported,
//         scanner.failOn(span, "oops: {}", .{123}),
//     );
//     try testing.expectEqualStrings(
//         \\test.txt:2:1: "bar": oops: 123
//     , log.items);
// }
