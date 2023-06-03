// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Post = @This();

source: []const u8,
filename: []const u8,
slug: []const u8,
metadata: Metadata,
markdown_offset: usize,
markdown_location: Reporter.Location,

pub fn parse(scanner: *Scanner) !Post {
    const metadata = try Metadata.parse(scanner);
    return Post{
        .source = scanner.source,
        .filename = scanner.filename,
        .slug = std.fs.path.stem(scanner.filename),
        .metadata = metadata,
        .markdown_offset = scanner.offset,
        .markdown_location = scanner.location,
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
        .filename = filename,
        .slug = "foo",
        .metadata = Metadata{
            .title = "The title",
            .description = "The description",
            .category = "Category",
            .status = Status{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .markdown_offset = 105,
        .markdown_location = .{ .line = 7, .column = 1 },
    };
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    try testing.expectEqualDeep(expected, try parse(&scanner));
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
        inline for (.{ "title", "description", "category" }) |key| {
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, Metadata.parse(&scanner));
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
        \\<input>:5:1: expected "date: " or "---\n", got "invali"
    ;
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, Metadata.parse(&scanner));
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, Metadata.parse(&scanner));
}
