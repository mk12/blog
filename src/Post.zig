// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Metadata = @import("Metadata.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;
const Post = @This();

filename: []const u8,
slug: []const u8,
meta: Metadata,
body: Span,

pub fn parse(scanner: *Scanner) Reporter.Error!Post {
    const meta = try Metadata.parse(scanner);
    return Post{
        .filename = scanner.filename,
        .slug = std.fs.path.stem(scanner.filename),
        .meta = meta,
        .body = Span{
            .text = scanner.source[scanner.offset..],
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
        .filename = filename,
        .slug = "foo",
        .meta = Metadata{
            .title = .{ .text = "The title", .location = .{ .line = 2, .column = 8 } },
            .subtitle = .{ .text = "The subtitle", .location = .{ .line = 3, .column = 11 } },
            .category = "Category",
            .status = .{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .body = .{ .text = source[99..], .location = .{ .line = 7, .column = 1 } },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    const post = try parse(&scanner);
    try testing.expectEqualStrings(expected.body.text, post.body.text);
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
