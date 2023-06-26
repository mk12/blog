// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Markdown = @import("Markdown.zig");
const Metadata = @import("Metadata.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Post = @This();

slug: []const u8,
meta: Metadata,
body: Markdown,

pub fn parse(scanner: *Scanner) Reporter.Error!Post {
    const meta = try Metadata.parse(scanner);
    return Post{
        .slug = std.fs.path.stem(scanner.filename),
        .meta = meta,
        .body = Markdown{
            .source = scanner.source[scanner.offset..],
            .filename = scanner.filename,
            .location = scanner.location,
        },
    };
}

test "parse" {
    const filename = "foo.md";
    const source =
        \\---
        \\title: The title
        \\subtitle: The subtitle
        \\category: Category
        \\date: 2023-04-29T15:28:50-07:00
        \\---
        \\
        \\Hello world!
    ;
    const expected = Post{
        .slug = "foo",
        .meta = Metadata{
            .title = "The title",
            .subtitle = "The subtitle",
            .category = "Category",
            .status = .{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .body = Markdown{
            .source = source[99..],
            .filename = filename,
            .location = .{ .line = 7, .column = 1 },
        },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    const post = try parse(&scanner);
    try testing.expectEqualStrings(expected.body.source, post.body.source);
    try testing.expectEqualDeep(expected, post);
}

pub fn order(lhs: Post, rhs: Post) std.math.Order {
    return switch (lhs.meta.status) {
        .draft => switch (rhs.meta.status) {
            .draft => std.mem.order(u8, lhs.slug, rhs.slug),
            .published => .gt,
        },
        .published => |lhs_date| switch (rhs.meta.status) {
            .draft => .lt,
            .published => |rhs_date| std.math.order(lhs_date.sortKey(), rhs_date.sortKey()),
        },
    };
}
