// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;
const Metadata = @This();

title: Span,
subtitle: Span,
category: []const u8,
status: Status,

pub const Status = union(enum) {
    draft,
    published: Date,
};

pub fn parse(scanner: *Scanner) Reporter.Error!Metadata {
    var meta: Metadata = undefined;
    const separator = "---\n";
    try scanner.expect(separator);
    inline for (.{ "title", "subtitle" }) |key| {
        try scanner.expect(key ++ ": ");
        @field(meta, key) = try scanner.until('\n');
    }
    try scanner.expect("category: ");
    meta.category = (try scanner.until('\n')).text;
    switch (try scanner.choice(.{ .date = "date: ", .end = separator })) {
        .date => {
            const date = try Date.parse(scanner);
            try scanner.expect("\n");
            meta.status = Status{ .published = date };
            try scanner.expect(separator);
        },
        .end => meta.status = Status.draft,
    }
    return meta;
}

fn expectSuccess(expected: Metadata, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try testing.expectEqualDeep(expected, try parse(&scanner));
}

fn expectFailure(expected_message: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, parse(&scanner));
}

test "draft" {
    try expectSuccess(Metadata{
        .title = .{ .text = "The title", .location = .{ .line = 2, .column = 8 } },
        .subtitle = .{ .text = "The subtitle", .location = .{ .line = 3, .column = 11 } },
        .category = "Category",
        .status = .draft,
    },
        \\---
        \\title: The title
        \\subtitle: The subtitle
        \\category: Category
        \\---
        \\
    );
}

test "published" {
    try expectSuccess(Metadata{
        .title = .{ .text = "The title", .location = .{ .line = 2, .column = 8 } },
        .subtitle = .{ .text = "The subtitle", .location = .{ .line = 3, .column = 11 } },
        .category = "Category",
        .status = .{ .published = Date.from("2023-04-29T15:28:50-07:00") },
    },
        \\---
        \\title: The title
        \\subtitle: The subtitle
        \\category: Category
        \\date: 2023-04-29T15:28:50-07:00
        \\---
        \\
    );
}

test "missing fields" {
    try expectFailure(
        \\<input>:3:1: expected "subtitle: ", got "---\n"
    ,
        \\---
        \\title: The title
        \\---
        \\
    );
}

test "invalid field" {
    try expectFailure(
        \\<input>:5:1: expected "date: " or "---\n", got "invali"
    ,
        \\---
        \\title: The title
        \\subtitle: The subtitle
        \\category: Category
        \\invalid: This is invalid!
        \\---
        \\
    );
}

test "invalid date" {
    try expectFailure(
        \\<input>:5:17: expected "T", got "?"
    ,
        \\---
        \\title: The title
        \\subtitle: The subtitle
        \\category: Category
        \\date: 2023-04-29?15:28:50-07:00
        \\---
        \\
    );
}
