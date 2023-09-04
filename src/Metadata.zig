// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module defines the metadata fields for blog posts. It parses them from
//! a restricted form of YAML at the top of each file, between "---" lines.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Metadata = @This();

title: []const u8,
subtitle: []const u8,
category: []const u8,
status: Status,

pub const Status = union(enum) {
    draft,
    published: Date,
};

pub fn parse(scanner: *Scanner) Reporter.Error!Metadata {
    var meta: Metadata = undefined;
    const separator = "---\n";
    try scanner.expectString(separator);
    inline for (.{ "title", "subtitle", "category" }) |key| {
        try scanner.expectString(key ++ ": ");
        @field(meta, key) = try scanner.expectUntil('\n');
    }
    if (scanner.consumeString("date: ")) {
        meta.status = Status{ .published = try Date.parse(scanner) };
        try scanner.expect('\n');
    } else {
        meta.status = Status.draft;
    }
    try scanner.expectString(separator);
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
        .title = "The title",
        .subtitle = "The subtitle",
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
        .title = "The title",
        .subtitle = "The subtitle",
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
        \\<input>:5:1: expected "---\n", got "inva"
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

test "incomplete header" {
    try expectFailure(
        \\<input>:2:17: unexpected EOF while looking for "\n"
    ,
        \\---
        \\title: The title
    );
}
