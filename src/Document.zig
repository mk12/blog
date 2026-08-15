// Copyright 2024 Mitchell Kember. Subject to the MIT License.

//! This module parses Markdown documents with YAML-ish frontmatter.

const constants = @import("constants.zig");
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Date = @import("Date.zig");
const Markdown = @import("Markdown.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Value = @import("Template.zig").Value;
const Document = @This();

slug: []const u8,
date: ?Date,
template: []const u8,
default_template: bool,
fields: std.ArrayList(Field),
body: []const u8,
context: Markdown.Context,

const Field = struct { key: []const u8, value: []const u8 };

pub const Options = struct {
    default_template: []const u8,
    date_required: bool = false,
};

pub fn parse(allocator: Allocator, scanner: *Scanner, options: Options) !Document {
    var date: ?Date = null;
    var template = options.default_template;
    var default_template = true;
    var fields: std.ArrayList(Field) = .empty;
    const separator = "---\n";
    var date_location = scanner.offset;
    if (scanner.consumeString(separator)) {
        while (scanner.peek() != separator[0]) {
            scanner.skipMany('\n');
            if (scanner.consume('#')) {
                _ = scanner.consumeUntilEol();
                continue;
            }
            const start = scanner.offset;
            while (scanner.peek()) |char| switch (char) {
                'A'...'Z', 'a'...'z', '0'...'9', '_' => scanner.eat(),
                else => break,
            };
            if (scanner.offset == start) return scanner.fail("expected an identifier", .{});
            const key = scanner.source[start..scanner.offset];
            try scanner.expectString(": ");
            if (std.mem.eql(u8, key, "date")) {
                date = try Date.parse(scanner);
                try scanner.expect('\n');
            } else if (std.mem.eql(u8, key, "template")) {
                template = scanner.consumeUntilEol();
                default_template = false;
            } else {
                try fields.append(allocator, Field{ .key = key, .value = scanner.consumeUntilEol() });
            }
        }
        date_location = scanner.offset;
        try scanner.expectString(separator);
    }
    if (options.date_required and date == null) return scanner.failAtOffset(date_location, "missing required field \"date\"", .{});
    scanner.skipMany('\n');
    const markdown = try Markdown.parse(allocator, scanner);
    const slug, _ = parseSlug(scanner.filename);
    return Document{ .slug = slug, .date = date, .template = template, .default_template = default_template, .fields = fields, .body = markdown.text, .context = markdown.context };
}

pub fn parseSlug(filename: []const u8) struct { []const u8, bool } {
    const stem = std.fs.path.stem(filename);
    if (std.mem.eql(u8, stem, "index")) return .{ std.fs.path.stem(std.fs.path.dirname(filename).?), true };
    return .{ stem, false };
}

pub fn path(self: *const Document) []const u8 {
    return self.context.filename;
}

pub fn insertMetadata(self: *const Document, allocator: Allocator, dict: *std.StringHashMapUnmanaged(Value)) !void {
    for (self.fields.items) |field| try dict.put(allocator, field.key, inferValue(field.value, self.context));
}

fn inferValue(opt_string: ?[]const u8, context: Markdown.Context) Value {
    const string = opt_string orelse return Value.null;
    if (string.len > 0 and string[0] == '&')
        return Value{ .reference = .{ .variable = string[1..], .source = context.source, .filename = context.filename } };
    for (string) |char| switch (char) {
        ' ', '\'' => return Value{ .markdown = .{ .markdown = Markdown{ .text = string, .context = context }, .options = .{ .is_inline = true } } },
        else => {},
    };
    return Value{ .string = string };
}

test "parse without frontmatter" {
    const filename = "foo.md";
    const source = "Hello world!";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    const post = try Document.parse(allocator, &scanner, .{ .default_template = "page.html" });
    try testing.expectEqualStrings("page.html", post.template);
    try testing.expectEqual(@as(usize, 0), post.fields.items.len);
    try testing.expectEqualStrings("Hello world!", post.body);
    try testing.expectEqualDeep(
        Markdown.Context{ .source = source, .filename = filename, .links = .{} },
        post.context,
    );
}

test "parse post" {
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .filename = filename, .reporter = &reporter };
    const post = try Document.parse(allocator, &scanner, .{ .default_template = "page.html" });
    try testing.expectEqualDeep(Date.from("2023-04-29T15:28:50-07:00"), post.date.?);
    try testing.expectEqualStrings("page.html", post.template);
    try testing.expectEqual(@as(usize, 3), post.fields.items.len);
    try testing.expectEqualDeep(Field{ .key = "title", .value = "The title" }, post.fields.items[0]);
    try testing.expectEqualDeep(Field{ .key = "subtitle", .value = "The subtitle" }, post.fields.items[1]);
    try testing.expectEqualDeep(Field{ .key = "category", .value = "Category" }, post.fields.items[2]);
    try testing.expectEqualStrings("Hello world!", post.body);
    try testing.expectEqualDeep(
        Markdown.Context{ .source = source, .filename = filename, .links = .{} },
        post.context,
    );
}
