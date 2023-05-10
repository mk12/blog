// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmtEscapes = std.zig.fmtEscapes;
const Scanner = @This();

allocator: Allocator,
source: []const u8,
position: Position,
error_message: ?[]const u8 = null,

pub const Error = error{ScanError} || std.fmt.AllocPrintError;

pub const Position = struct {
    filename: []const u8,
    offset: u32 = 0,
    line: u16 = 1,
    column: u16 = 1,

    fn format(position: Position) std.fmt.Formatter(formatPosition) {
        return .{ .data = position };
    }
};

fn formatPosition(
    position: Position,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    if (fmt.len != 0) @compileError("expected {}, found {" ++ fmt ++ "}");
    try std.fmt.format(writer, "{s}:{}:{}", .{ position.filename, position.line, position.column });
}

pub fn init(allocator: Allocator, filename: []const u8, source: []const u8) Scanner {
    return Scanner{
        .allocator = allocator,
        .source = source,
        .position = .{ .filename = filename },
    };
}

pub fn deinit(scanner: *Scanner) void {
    if (scanner.error_message) |message| {
        scanner.allocator.free(message);
    }
}

pub fn failAt(scanner: *Scanner, position: Position, comptime format: []const u8, args: anytype) Error {
    scanner.error_message = try std.fmt.allocPrint(
        scanner.allocator,
        "{}: " ++ format,
        .{position.format()} ++ args,
    );
    return error.ScanError;
}

pub fn fail(scanner: *Scanner, comptime format: []const u8, args: anytype) Error {
    return scanner.failAt(scanner.position, format, args);
}

pub fn eof(scanner: *const Scanner) bool {
    return scanner.position.offset == scanner.source.len;
}

pub fn peek(scanner: *const Scanner) ?u8 {
    return if (scanner.eof()) null else scanner.source[scanner.position.offset];
}

pub fn consume(scanner: *Scanner) ?u8 {
    if (scanner.eof()) return null;
    const character = scanner.source[scanner.position.offset];
    scanner.position.offset += 1;
    if (character == '\n') {
        scanner.position.line += 1;
        scanner.position.column = 1;
    } else {
        scanner.position.column += 1;
    }
    return character;
}

pub fn until(scanner: *Scanner, end: u8) Error![]const u8 {
    const start = scanner.position.offset;
    while (scanner.consume()) |character|
        if (character == end) return scanner.source[start .. scanner.position.offset - 1];
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
    scanner.position.column = columns orelse scanner.position.column + @intCast(u16, expected.len);
}
