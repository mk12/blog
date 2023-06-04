// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Date = @import("Date.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Metadata = @This();

title: []const u8,
description: []const u8,
category: []const u8,
status: Status,

const Status = union(enum) {
    draft,
    published: Date,
};

pub fn parse(scanner: *Scanner) Reporter.Error!Metadata {
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

fn expectSuccess(expected: Metadata, source: []const u8) !void {
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try testing.expectEqualDeep(expected, try Metadata.parse(&scanner));
}

fn expectFailure(expected_message: []const u8, source: []const u8) !void {
    var reporter = Reporter{};
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, Metadata.parse(&scanner));
}

test "draft" {
    try expectSuccess(Metadata{
        .title = "The title",
        .description = "The description",
        .category = "Category",
        .status = Status.draft,
    },
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\---
        \\
    );
}

test "published" {
    try expectSuccess(Metadata{
        .title = "The title",
        .description = "The description",
        .category = "Category",
        .status = Status{ .published = Date.from("2023-04-29T15:28:50-07:00") },
    },
        \\---
        \\title: The title
        \\description: The description
        \\category: Category
        \\date: 2023-04-29T15:28:50-07:00
        \\---
        \\
    );
}

test "missing fields" {
    try expectFailure(
        \\<input>:3:1: expected "description: ", got "---\n"
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
        \\description: The description
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
        \\description: The description
        \\category: Category
        \\date: 2023-04-29?15:28:50-07:00
        \\---
        \\
    );
}
