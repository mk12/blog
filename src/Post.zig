// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Date = @import("Date.zig");
const Markdown = @import("Markdown.zig");
const Metadata = @import("Metadata.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;
const Post = @This();

slug: []const u8,
meta: Metadata,
// Maybe content should be span too, don't privilege it over others?
// But then is that just what I had before?
content: Markdown,

pub fn parse(allocator: Allocator, scanner: *Scanner) !Post {
    const slug = std.fs.path.stem(scanner.filename);
    const meta = try Metadata.parse(scanner);
    const content = try Markdown.parse(allocator, scanner);
    return Post{ .slug = slug, .meta = meta, .content = content };
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
            .title = .{ .text = "The title", .location = .{ .line = 2, .column = 8 } },
            .subtitle = .{ .text = "The subtitle", .location = .{ .line = 3, .column = 11 } },
            .category = "Category",
            .status = .{ .published = Date.from("2023-04-29T15:28:50-07:00") },
        },
        .content = .{
            .context = .{ .filename = filename, .links = .{} },
            .span = .{ .text = source[99..], .location = .{ .line = 7, .column = 1 } },
        },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    const post = try parse(allocator, &scanner);
    try testing.expectEqualStrings(expected.content.span.text, post.content.span.text);
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
