// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Metadata = @import("Metadata.zig");
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
            .status = .{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .markdown_offset = 105,
        .markdown_location = .{ .line = 7, .column = 1 },
    };
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    try testing.expectEqualDeep(expected, try parse(&scanner));
}
