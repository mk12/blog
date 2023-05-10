// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const testing = std.testing;
const Scanner = @import("Scanner.zig");
const Post = @This();

source: []const u8,
slug: []const u8,
metadata: Metadata,
markdown_start: Scanner.Position,

const Metadata = struct {
    title: []const u8,
    description: []const u8,
    category: []const u8,
    status: Status,
};

const Status = union(enum) {
    draft: void,
    published: Date,
};

pub fn parse(allocator: Allocator, filename: []const u8, source: []const u8) !Post {
    var scanner = Scanner.init(allocator, filename, source);
    const metadata = try parseMetadata(&scanner);
    return Post{
        .source = source,
        .slug = std.fs.path.stem(filename),
        .metadata = metadata,
        .markdown_start = scanner.position,
    };
}

fn parseMetadata(scanner: *Scanner) !Metadata {
    var metadata: Metadata = undefined;
    try scanner.expect("---\n");
    const required = [_][]const u8{ "title", "description", "category" };
    inline for (required) |key| {
        try scanner.expect(key ++ ": ");
        @field(metadata, key) = try scanner.until('\n');
    }
    metadata.status = blk: {
        if (scanner.peek()) |c| if (c == '-') break :blk Status.draft;
        try scanner.expect("date: ");
        const date_position = scanner.position;
        const date_str = try scanner.until('\n');
        const date = parseDate(date_str) catch |err| return scanner.failAt(
            date_position,
            "\"{}\": invalid date: {s}",
            .{ std.zig.fmtEscapes(date_str), @errorName(err) },
        );
        break :blk Status{ .published = date };
    };
    try scanner.expect("---\n");
    return metadata;
}

test "parseMetadata draft" {
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\---
        \\
    ;
    var scanner = Scanner.init(std.testing.allocator, "test.md", source);
    defer scanner.deinit();
    try testing.expectEqualDeep(
        Metadata{
            .title = "The title",
            .description = "The description",
            .category = "Category",
            .status = Status.draft,
        },
        try parseMetadata(&scanner),
    );
}

test "parseMetadata published" {
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\date: 2023-04-29T15:28:50-07:00
        \\---
        \\
    ;
    var scanner = Scanner.init(std.testing.allocator, "test.md", source);
    defer scanner.deinit();
    try testing.expectEqualDeep(
        Metadata{
            .title = "The title",
            .description = "The description",
            .category = "Category",
            .status = Status{ .published = try parseDate("2023-04-29T15:28:50-07:00") },
        },
        try parseMetadata(&scanner),
    );
}

test "parseMetadata missing fields" {
    const source =
        \\---
        \\title: The title
        \\---
        \\
    ;
    var scanner = Scanner.init(std.testing.allocator, "test.md", source);
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parseMetadata(&scanner));
    try testing.expectEqualStrings(
        \\test.md:3:1: expected "description: ", got "---\n"
    , scanner.error_message.?);
}

// test "parseMetadata invalid date" {
//     const source =
//         \\---
//         \\title: The title
//         \\description: The description
//         \\category: Category
//         \\date: 2023-04-29?15:28:50-07:00
//         \\---
//         \\
//     ;
//     var scanner = Scanner.init(std.testing.allocator, "test.md", source);
//     defer scanner.deinit();
//     try testing.expectError(error.ScanError, parseMetadata(&scanner));
//     try testing.expectEqualStrings(
//         \\test.md:3:1: expected "description: ", got "---\n"
//     , scanner.error_message.?);
// }

const Date = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    tz_offset_h: i8,
};

// fn parseDate2(scanner: *Scanner) !Date {

// }

fn parseDate(str: []const u8) !Date {
    if (str.len != "0000-00-00T00:00:00-00:00".len) return error.DateWrongLength;
    inline for ([_]usize{ 4, 7 }) |i| if (str[i] != '-') return error.DateMissingHyphen;
    inline for ([_]usize{ 13, 16, 22 }) |i| if (str[i] != ':') return error.DateMissingColon;
    if (str[10] != 'T') return error.DateExpectedT;
    if (!std.mem.eql(u8, str[23..], "00")) return error.DateInvalidTzMinute;
    return Date{
        .year = fmt.parseUnsigned(u16, str[0..4], 10) catch return error.DateInvalidYear,
        .month = fmt.parseUnsigned(u8, str[5..7], 10) catch return error.DateInvalidMonth,
        .day = fmt.parseUnsigned(u8, str[8..10], 10) catch return error.DateInvalidDay,
        .hour = fmt.parseUnsigned(u8, str[11..13], 10) catch return error.DateInvalidHour,
        .minute = fmt.parseUnsigned(u8, str[14..16], 10) catch return error.DateInvalidMinute,
        .second = fmt.parseUnsigned(u8, str[17..19], 10) catch return error.DateInvalidSecond,
        .tz_offset_h = fmt.parseInt(i8, str[19..22], 10) catch return error.DateInvalidTzHour,
    };
}

test "parseDate" {
    try testing.expectError(error.DateWrongLength, parseDate(""));
    try testing.expectError(error.DateWrongLength, parseDate("not a date"));
    try testing.expectEqual(
        Date{ .year = 2023, .month = 4, .day = 29, .hour = 10, .minute = 6, .second = 12, .tz_offset_h = -7 },
        try parseDate("2023-04-29T10:06:12-07:00"),
    );
}
