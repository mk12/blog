// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Scanner = @import("Scanner.zig");
const Post = @This();
const Date = @import("Date.zig");

source: []const u8,
slug: []const u8,
metadata: Metadata,
markdown_start: Scanner.Position,

pub fn parse(scanner: *Scanner) !Post {
    const metadata = try Metadata.parse(scanner);
    return Post{
        .source = scanner.source,
        .slug = std.fs.path.stem(scanner.filename),
        .metadata = metadata,
        .markdown_start = scanner.pos,
    };
}

const Status = union(enum) {
    draft: void,
    published: Date,
};

const Metadata = struct {
    title: []const u8,
    description: []const u8,
    category: []const u8,
    status: Status,

    fn parse(scanner: *Scanner) !Metadata {
        var metadata: Metadata = undefined;
        try scanner.expect("---\n");
        const required = [_][]const u8{ "title", "description", "category" };
        inline for (required) |key| {
            try scanner.expect(key ++ ": ");
            const token = try scanner.consumeUntil('\n');
            @field(metadata, key) = token.text;
        }
        metadata.status = blk: {
            if (scanner.peek()) |c| if (c == '-') break :blk Status.draft;
            try scanner.expect("date: ");
            const date = try Date.parse(scanner);
            try scanner.expect("\n");
            break :blk Status{ .published = date };
        };
        try scanner.expect("---\n");
        return metadata;
    }
};

test "parse metadata draft" {
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\---
        \\
    ;
    const expected = Metadata{
        .title = "The title",
        .description = "The description",
        .category = "Category",
        .status = Status.draft,
    };
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectEqualDeep(expected, try Metadata.parse(&scanner));
}

const sample_date = Date{ .year = 2023, .month = 4, .day = 29, .hour = 15, .minute = 28, .second = 50, .tz_offset_h = -7 };

test "parse metadata published" {
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\date: 2023-04-29T15:28:50-07:00
        \\---
        \\
    ;
    const expected = Metadata{
        .title = "The title",
        .description = "The description",
        .category = "Category",
        .status = Status{ .published = sample_date },
    };
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectEqualDeep(expected, try Metadata.parse(&scanner));
}

test "parse metadata missing fields" {
    const source =
        \\---
        \\title: The title
        \\---
        \\
    ;
    const expected_error =
        \\<input>:3:1: expected "description: ", got "---\n"
    ;
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectError(error.ScanError, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "parse metadata invalid date" {
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\date: 2023-04-29?15:28:50-07:00
        \\---
        \\
    ;
    const expected_error =
        \\<input>:5:17: expected "T", got "?"
    ;
    var scanner = Scanner.init(testing.allocator, source);
    defer scanner.deinit();
    try testing.expectError(error.ScanError, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "parse post" {
    const filename = "foo.md";
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\date: 2023-04-29T15:28:50-07:00
        \\---
        \\
        \\Hello world!
    ;
    const expected = Post{
        .source = source,
        .slug = "foo",
        .metadata = Metadata{
            .title = "The title",
            .description = "The description",
            .category = "Category",
            .status = Status{ .published = sample_date },
        },
        .markdown_start = Scanner.Position{
            .offset = 105,
            .line = 7,
            .column = 1,
        },
    };
    var scanner = Scanner.init(testing.allocator, source);
    scanner.filename = filename;
    defer scanner.deinit();
    try testing.expectEqualDeep(expected, try parse(&scanner));
}
