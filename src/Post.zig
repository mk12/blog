// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Date = @import("Date.zig");
const Scanner = @import("Scanner.zig");
const Post = @This();

source: []const u8,
filename: []const u8,
slug: []const u8,
metadata: Metadata,
markdown_start: Scanner.Position,

pub fn parse(scanner: *Scanner) !Post {
    const metadata = try Metadata.parse(scanner);
    const after_metadata = scanner.pos;
    return Post{
        .source = scanner.source,
        .filename = scanner.filename,
        .slug = std.fs.path.stem(scanner.filename),
        .metadata = metadata,
        .markdown_start = after_metadata,
    };
}

test "parse" {
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
        .filename = "foo.md",
        .slug = "foo",
        .metadata = Metadata{
            .title = "The title",
            .description = "The description",
            .category = "Category",
            .status = Status{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .markdown_start = Scanner.Position{
            .offset = 105,
            .line = 7,
            .column = 1,
        },
    };
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    scanner.filename = filename;
    try testing.expectEqualDeep(expected, try parse(&scanner));
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
        const separator = "---\n";
        try scanner.consume(separator);
        const required = [_][]const u8{ "title", "description", "category" };
        inline for (required) |key| {
            try scanner.consume(key ++ ": ");
            const span = try scanner.consumeUntil('\n');
            @field(metadata, key) = span.text;
        }
        switch (try scanner.consumeOneOf(.{ .date = "date: ", .end = separator })) {
            .date => {
                const date = try Date.parse(scanner);
                try scanner.consume("\n");
                metadata.status = Status{ .published = date };
                try scanner.consume(separator);
            },
            .end => metadata.status = Status.draft,
        }
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
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    try testing.expectEqualDeep(expected, try Metadata.parse(&scanner));
}

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
        .status = Status{ .published = Date.from("2023-04-29T15:28:50-07:00") },
    };
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
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
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    try testing.expectError(error.ScanError, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "parse metadata invalid field" {
    const source =
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\invalid: This is invalid!
        \\---
        \\
    ;
    const expected_error =
        \\<input>:5:1: expected one of: "date: ", "---\n"
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
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
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    try testing.expectError(error.ScanError, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}
