// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const Scanner = @import("Scanner.zig");
const Date = @This();

year: u16,
month: u8,
day: u8,
hour: u8,
minute: u8,
second: u8,
tz_offset_h: i8,

/// Parses a date from a restricted subset of RFC-3339.
pub fn parse(scanner: *Scanner) !Date {
    var date: Date = undefined;
    try parseField(scanner, &date.year, 4, "year");
    try scanner.consume("-");
    try parseField(scanner, &date.month, 2, "month");
    try scanner.consume("-");
    try parseField(scanner, &date.day, 2, "day");
    try scanner.consume("T");
    try parseField(scanner, &date.hour, 2, "hour");
    try scanner.consume(":");
    try parseField(scanner, &date.minute, 2, "minute");
    try scanner.consume(":");
    try parseField(scanner, &date.second, 2, "second");
    try parseField(scanner, &date.tz_offset_h, 3, "timezone hour offset");
    try scanner.consume(":00");
    return date;
}

fn parseField(scanner: *Scanner, field_ptr: anytype, length: usize, name: []const u8) !void {
    const T = @typeInfo(@TypeOf(field_ptr)).Pointer.child;
    const span = try scanner.consumeFixed(length);
    const parseNumber = switch (@typeInfo(T).Int.signedness) {
        .signed => fmt.parseInt,
        .unsigned => fmt.parseUnsigned,
    };
    field_ptr.* = parseNumber(T, span.text, 10) catch
        return scanner.failOn(span, "invalid {s}", .{name});
}

/// Parses a date at comptime.
pub fn from(comptime string: []const u8) Date {
    var scanner = Scanner.init(null, string);
    return parse(&scanner) catch unreachable;
}

test "parse valid date" {
    const source = "2023-04-29T10:06:12-07:00";
    const expected = Date{ .year = 2023, .month = 4, .day = 29, .hour = 10, .minute = 6, .second = 12, .tz_offset_h = -7 };
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    const actual = parse(&scanner) catch {
        std.debug.print("{s}\n", .{scanner.error_message.?});
        return error.TestParseFailed;
    };
    try testing.expectEqual(expected, actual);
}

test "parse empty date" {
    const source = "";
    const expected_error =
        \\<input>:1:1: unexpected EOF
    ;
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parse(&scanner));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "parse invalid date" {
    const source = "2023-04-29T1z:06:12-07:00";
    const expected_error =
        \\<input>:1:12: "1z": invalid hour
    ;
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parse(&scanner));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "comptime from" {
    comptime {
        const expected = Date{ .year = 1900, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .tz_offset_h = 6 };
        try testing.expectEqual(expected, from("1900-01-02T03:04:05+06:00"));
    }
}
