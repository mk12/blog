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

pub fn parse(scanner: *Scanner) !Date {
    var date: Date = undefined;
    date.year = try field(scanner, u16, "year", 4);
    try scanner.expect("-");
    date.month = try field(scanner, u8, "month", 2);
    try scanner.expect("-");
    date.day = try field(scanner, u8, "day", 2);
    try scanner.expect("T");
    date.hour = try field(scanner, u8, "hour", 2);
    try scanner.expect(":");
    date.minute = try field(scanner, u8, "minute", 2);
    try scanner.expect(":");
    date.second = try field(scanner, u8, "second", 2);
    date.tz_offset_h = try field(scanner, i8, "timezone hour offset", 3);
    try scanner.expect(":00");
    return date;
}

fn field(scanner: *Scanner, comptime T: type, name: []const u8, length: usize) !T {
    const token = try scanner.consumeBytes(length);
    const parseNumber = switch (@typeInfo(T).Int.signedness) {
        .signed => fmt.parseInt,
        .unsigned => fmt.parseUnsigned,
    };
    return parseNumber(T, token.text, 10) catch scanner.failOn(token, "invalid {s}", .{name});
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

test "parse valid date" {
    const source = "2023-04-29T10:06:12-07:00";
    const expected = Date{
        .year = 2023,
        .month = 4,
        .day = 29,
        .hour = 10,
        .minute = 6,
        .second = 12,
        .tz_offset_h = -7,
    };
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectEqual(expected, try parse(&scanner));
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
