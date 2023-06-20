// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
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
pub fn parse(scanner: *Scanner) Reporter.Error!Date {
    var date: Date = undefined;
    try parseField(scanner, 4, &date, "year", 2000, 2099);
    try scanner.expect("-");
    try parseField(scanner, 2, &date, "month", 1, 12);
    try scanner.expect("-");
    try parseField(scanner, 2, &date, "day", 1, daysInMonth(date.month, date.year));
    try scanner.expect("T");
    try parseField(scanner, 2, &date, "hour", 0, 23);
    try scanner.expect(":");
    try parseField(scanner, 2, &date, "minute", 0, 59);
    try scanner.expect(":");
    try parseField(scanner, 2, &date, "second", 0, 60); // leap second
    try parseField(scanner, 3, &date, "tz_offset_h", -12, 14);
    try scanner.expect(":00");
    return date;
}

pub inline fn from(comptime string: []const u8) Date {
    comptime {
        var fba = std.heap.FixedBufferAllocator.init(&[0]u8{});
        var reporter = Reporter.init(fba.allocator());
        var scanner = Scanner{ .source = string, .reporter = &reporter };
        return parse(&scanner) catch unreachable;
    }
}

fn parseField(
    scanner: *Scanner,
    length: usize,
    date: *Date,
    comptime name: []const u8,
    min: @TypeOf(@field(date, name)),
    max: @TypeOf(@field(date, name)),
) !void {
    const FieldType = @TypeOf(@field(date, name));
    const span = try scanner.consume(length);
    const parseNumber = switch (@typeInfo(FieldType).Int.signedness) {
        .signed => std.fmt.parseInt,
        .unsigned => std.fmt.parseUnsigned,
    };
    const value = parseNumber(FieldType, span.text, 10) catch
        return scanner.failOn(span, "invalid {s}", .{name});
    if (value < min or value > max)
        return scanner.failOn(span, "{s} must be from {} to {}", .{ name, min, max });
    @field(date, name) = value;
}

fn expectSuccess(expected: Date, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try testing.expectEqual(expected, try parse(&scanner));
}

fn expectFailure(expected_message: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, parse(&scanner));
}

test "parse valid" {
    try expectSuccess(
        Date{ .year = 2002, .month = 12, .day = 31, .hour = 14, .minute = 59, .second = 1, .tz_offset_h = 0 },
        "2002-12-31T14:59:01+00:00",
    );
    try expectSuccess(
        Date{ .year = 2023, .month = 4, .day = 29, .hour = 10, .minute = 6, .second = 12, .tz_offset_h = -7 },
        "2023-04-29T10:06:12-07:00",
    );
}

test "parse invalid" {
    try expectFailure("<input>:1:1: unexpected EOF", "");
    try expectFailure("<input>:1:1: \"asdf\": invalid year", "asdf");
    try expectFailure("<input>:1:5: expected \"-\", got \".\"", "2000.");
    try expectFailure("<input>:1:12: \"1z\": invalid hour", "2023-04-29T1z:06:12-07:00");
    try expectFailure("<input>:1:6: \"00\": month must be from 1 to 12", "2023-00-29T10:06:12-07:00");
}

test "comptime from" {
    comptime try testing.expectEqual(
        Date{ .year = 2001, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .tz_offset_h = 6 },
        from("2001-01-02T03:04:05+06:00"),
    );
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

const days_in_month_non_leap = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn daysInMonth(month: u8, year: u16) u8 {
    return if (month == 2 and isLeapYear(year)) 29 else days_in_month_non_leap[month - 1];
}

const month_names = [12][]const u8{
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
};

fn monthName(date: Date) []const u8 {
    return month_names[date.month - 1];
}

const weekday_names = [7][]const u8{
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
};

fn weekdayName(date: Date) []const u8 {
    assert(date.year >= 2000 and date.year <= 2099);
    const year_code = date.year + date.year / 4;
    const month_codes = [12]u8{ 0, 3, 3, 6, 1, 4, 6, 2, 5, 0, 3, 5 };
    const month_code = month_codes[date.month - 1];
    const century_code = 4;
    const leap_code = @boolToInt(date.month <= 2 and isLeapYear(date.year));
    const weekday = (year_code + month_code + century_code + date.day - leap_code) % 7;
    return weekday_names[weekday];
}

fn fmtDate(
    date: Date,
    comptime format: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    if (comptime std.mem.eql(u8, format, "short")) {
        try writer.print("{} {s} {}", .{ date.day, date.monthName()[0..3], date.year });
    } else if (comptime std.mem.eql(u8, format, "long")) {
        try writer.print("{s}, {} {s} {}", .{ date.weekdayName(), date.day, date.monthName(), date.year });
    } else if (comptime std.mem.eql(u8, format, "rfc3339")) {
        const sign: u8 = if (date.tz_offset_h < 0) '-' else '+';
        const offset = std.math.absCast(date.tz_offset_h);
        try writer.print(
            "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}{c}{:0>2}:00",
            .{ date.year, date.month, date.day, date.hour, date.minute, date.second, sign, offset },
        );
    } else {
        @compileError("invalid date format: " ++ format);
    }
}

pub fn fmt(date: Date) std.fmt.Formatter(fmtDate) {
    return .{ .data = date };
}

fn expectFmt(expected: []const u8, comptime format: []const u8, args: anytype) !void {
    const actual = try std.fmt.allocPrint(testing.allocator, format, args);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "fmt" {
    const original = "2023-06-09T16:30:07-07:00";
    const date = from(original);
    try expectFmt("9 Jun 2023", "{short}", .{date.fmt()});
    try expectFmt("Friday, 9 June 2023", "{long}", .{date.fmt()});
    try expectFmt(original, "{rfc3339}", .{date.fmt()});
}
