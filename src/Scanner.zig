// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fmtEscapes = std.zig.fmtEscapes;
const Scanner = @This();

pub const Error = error{LoggedScanError};

pub const Position = struct {
    offset: u32 = 0,
    line: u16 = 1,
    column: u16 = 1,
};

filename: []const u8,
source: []const u8,
position: Position = .{},

pub fn fail(scanner: *const Scanner, comptime format: []const u8, args: anytype) Error {
    std.log.err(
        "{s}:{}:{}: " ++ format,
        .{ scanner.filename, scanner.position.line, scanner.position.column } ++ args,
    );
    return error.LoggedScanError;
}

pub fn eof(scanner: *const Scanner) bool {
    return scanner.position.offset == scanner.source.len;
}

pub fn peek(scanner: *const Scanner) ?u8 {
    return if (scanner.eof()) null else scanner.source[scanner.position.offset];
}

pub fn consume(scanner: *Scanner) ?u8 {
    if (scanner.eof()) return null;
    const char = scanner.source[scanner.position.offset];
    scanner.position.offset += 1;
    if (char == '\n') {
        scanner.position.line += 1;
        scanner.position.column = 1;
    } else {
        scanner.position.column += 1;
    }
    return char;
}

pub fn until(scanner: *Scanner, end: u8) Error![]const u8 {
    const start = scanner.position.offset;
    while (scanner.consume()) |char|
        if (char == end) return scanner.source[start .. scanner.position.offset - 1];
    return scanner.fail("unexpected EOF looking for \"{}\"", .{fmtEscapes(&[_]u8{end})});
}

pub fn expect(scanner: *Scanner, comptime expected: []const u8) Error!void {
    const offset = scanner.position.offset;
    const actual = scanner.source[offset..std.math.min(offset + expected.len, scanner.source.len)];
    if (!std.mem.eql(u8, actual, expected))
        return scanner.fail("expected \"{}\", got \"{}\"", .{ fmtEscapes(expected), fmtEscapes(actual) });
    scanner.position.offset += @intCast(u32, expected.len);
    const newlines = comptime std.mem.count(u8, expected, "\n");
    const columns = comptime std.mem.lastIndexOfScalar(u8, expected, '\n');
    scanner.position.line += @intCast(u16, newlines);
    if (columns) |c| scanner.position.column = c else scanner.position.column += @intCast(u16, expected.len);
}
