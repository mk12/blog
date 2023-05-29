// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Scanner = @import("Scanner.zig");
const Post = @This();

slug: []const u8,
metadata: Metadata,
markdown_scanner: Scanner,

pub fn parse(scanner: Scanner) !Post {
    var mut_scanner = scanner;
    const metadata = try Metadata.parse(&mut_scanner);
    return Post{
        .slug = std.fs.path.stem(scanner.reporter.filename),
        .metadata = metadata,
        .markdown_scanner = mut_scanner,
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
        .slug = "foo",
        .metadata = Metadata{
            .title = "The title",
            .description = "The description",
            .category = "Category",
            .status = Status{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .markdown_scanner = Scanner{
            .source = source,
            .reporter = .{ .filename = filename },
            .offset = 105,
            .location = .{ .line = 7, .column = 1 },
        },
    };
    var scanner = Scanner{ .source = source, .reporter = .{ .filename = filename } };
    try testing.expectEqualDeep(expected, try parse(scanner));
}

const Status = union(enum) {
    draft,
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
        try scanner.expect(separator);
        const required = .{ "title", "description", "category" };
        inline for (required) |key| {
            try scanner.expect(key ++ ": ");
            const span = try scanner.until('\n');
            @field(metadata, key) = span.text;
        }
        switch (try scanner.choice(.{ .date = "date: ", .end = separator })) {
            .date => {
                const date = try Date.parse(scanner);
                try scanner.expect("\n");
                metadata.status = Status{ .published = date };
                try scanner.expect(separator);
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
    var scanner = Scanner{ .source = source };
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
    var scanner = Scanner{ .source = source };
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
    var log = std.ArrayList(u8).init(testing.allocator);
    defer log.deinit();
    var scanner = Scanner{ .source = source, .reporter = .{ .out = &log } };
    try testing.expectError(error.ErrorWasReported, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, log.items);
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
    var log = std.ArrayList(u8).init(testing.allocator);
    defer log.deinit();
    var scanner = Scanner{ .source = source, .reporter = .{ .out = &log } };
    try testing.expectError(error.ErrorWasReported, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, log.items);
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
    var log = std.ArrayList(u8).init(testing.allocator);
    defer log.deinit();
    var scanner = Scanner{ .source = source, .reporter = .{ .out = &log } };
    try testing.expectError(error.ErrorWasReported, Metadata.parse(&scanner));
    try testing.expectEqualStrings(expected_error, log.items);
}
