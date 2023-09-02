// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module defines the structure of a blog post. Basically, it consists of
//! a slug from the filename, metadata fields, and a Markdown body.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Date = @import("Date.zig");
const Markdown = @import("Markdown.zig");
const Metadata = @import("Metadata.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Post = @This();

slug: []const u8,
meta: Metadata,
body: []const u8,
context: Markdown.Context,

pub fn parse(allocator: Allocator, scanner: *Scanner) !Post {
    const slug = parseSlug(scanner.filename);
    const meta = try Metadata.parse(scanner);
    const markdown = try Markdown.parse(allocator, scanner);
    return Post{ .slug = slug, .meta = meta, .body = markdown.text, .context = markdown.context };
}

pub fn parseSlug(filename: []const u8) []const u8 {
    return std.fs.path.stem(filename);
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
        .body = "\nHello world!",
        .context = .{ .source = source, .filename = filename, .links = .{} },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    const post = try parse(allocator, &scanner);
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
