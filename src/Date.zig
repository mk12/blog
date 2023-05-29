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
    try parseField(scanner, &date, "year", 4);
    try scanner.expect("-");
    try parseField(scanner, &date, "month", 2);
    try scanner.expect("-");
    try parseField(scanner, &date, "day", 2);
    try scanner.expect("T");
    try parseField(scanner, &date, "hour", 2);
    try scanner.expect(":");
    try parseField(scanner, &date, "minute", 2);
    try scanner.expect(":");
    try parseField(scanner, &date, "second", 2);
    try parseField(scanner, &date, "tz_offset_h", 3);
    try scanner.expect(":00");
    return date;
}

/// Parses a date at comptime.
pub inline fn from(comptime string: []const u8) Date {
    comptime {
        var scanner = Scanner{ .source = string };
        return parse(&scanner) catch unreachable;
    }
}

fn parseField(scanner: *Scanner, date: *Date, comptime name: []const u8, length: usize) !void {
    const FieldType = @TypeOf(@field(date, name));
    const span = try scanner.consume(length);
    const parseNumber = switch (@typeInfo(FieldType).Int.signedness) {
        .signed => fmt.parseInt,
        .unsigned => fmt.parseUnsigned,
    };
    @field(date, name) = parseNumber(FieldType, span.text, 10) catch
        return scanner.failOn(span, "invalid {s}", .{name});
}

test "parse valid date" {
    const source = "2023-04-29T10:06:12-07:00";
    const expected = Date{ .year = 2023, .month = 4, .day = 29, .hour = 10, .minute = 6, .second = 12, .tz_offset_h = -7 };
    var scanner = Scanner{ .source = source };
    try testing.expectEqual(expected, try parse(&scanner));
}

test "parse empty date" {
    const source = "";
    const expected_error =
        \\<input>:1:1: unexpected EOF
    ;
    var log = std.ArrayList(u8).init(testing.allocator);
    defer log.deinit();
    var scanner = Scanner{ .source = source, .reporter = .{ .out = &log } };
    try testing.expectError(error.ErrorWasReported, parse(&scanner));
    try testing.expectEqualStrings(expected_error, log.items);
}

test "parse invalid date" {
    const source = "2023-04-29T1z:06:12-07:00";
    const expected_error =
        \\<input>:1:12: "1z": invalid hour
    ;
    var log = std.ArrayList(u8).init(testing.allocator);
    defer log.deinit();
    var scanner = Scanner{ .source = source, .reporter = .{ .out = &log } };
    try testing.expectError(error.ErrorWasReported, parse(&scanner));
    try testing.expectEqualStrings(expected_error, log.items);
}

test "comptime from" {
    comptime {
        const expected = Date{ .year = 1900, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .tz_offset_h = 6 };
        try testing.expectEqual(expected, from("1900-01-02T03:04:05+06:00"));
    }
}
