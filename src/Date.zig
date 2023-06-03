// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const Reporter = @import("Reporter.zig");
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

pub inline fn from(comptime string: []const u8) Date {
    comptime {
        var reporter = Reporter{};
        var scanner = Scanner{ .source = string, .reporter = &reporter };
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

fn expectValid(expected: Date, source: []const u8) !void {
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try testing.expectEqual(expected, try parse(&scanner));
}

fn expectInvalid(expected_error: []const u8, source: []const u8) !void {
    var reporter = Reporter{};
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, parse(&scanner));
}

test "parse valid" {
    try expectValid(
        Date{ .year = 1903, .month = 12, .day = 31, .hour = 14, .minute = 59, .second = 1, .tz_offset_h = 0 },
        "1903-12-31T14:59:01+00:00",
    );
    try expectValid(
        Date{ .year = 2023, .month = 4, .day = 29, .hour = 10, .minute = 6, .second = 12, .tz_offset_h = -7 },
        "2023-04-29T10:06:12-07:00",
    );
}

test "parse invalid" {
    try expectInvalid("<input>:1:1: unexpected EOF", "");
    try expectInvalid("<input>:1:1: \"asdf\": invalid year", "asdf");
    try expectInvalid("<input>:1:5: expected \"-\", got \".\"", "2000.");
    try expectInvalid("<input>:1:12: \"1z\": invalid hour", "2023-04-29T1z:06:12-07:00");
}

test "comptime from" {
    comptime {
        const expected = Date{ .year = 1900, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .tz_offset_h = 6 };
        try testing.expectEqual(expected, from("1900-01-02T03:04:05+06:00"));
    }
}
