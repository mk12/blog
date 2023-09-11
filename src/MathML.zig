// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module renders a subset of TeX to MathML.
//! It is driven one line at a time so that it can be used by the Markdown
//! renderer (where display math can be nested in blockquotes, for example).

const std = @import("std");
const testing = std.testing;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const MathML = @This();

// TODO: CodeRenderer, MathRenderer?

// TODO maybe is_display
kind: Kind = undefined,

const Kind = enum {
    @"inline",
    display,
};

pub fn begin(self: *MathML, writer: anytype, kind: Kind) !void {
    self.* = MathML{ .kind = kind };
    switch (kind) {
        .@"inline" => try writer.writeAll("<math>\n"),
        .display => try writer.writeAll("<math display=\"block\">\n"),
    }
}

pub fn feed(self: *MathML, writer: anytype, scanner: *Scanner) !bool {
    _ = scanner;
    _ = writer;
    _ = self;
}

fn expectSuccess(expected_mathml: []const u8, source: []const u8, kind: Kind) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_mathml = std.ArrayList(u8).init(allocator);
    const writer = actual_mathml.writer();
    var mathml = MathML{};
    try mathml.begin(writer, kind);
    try testing.expect(!try mathml.feed(writer, &scanner));
    try testing.expectEqualStrings(expected_mathml, actual_mathml.items);
}

// test "empty input" {
//     try expectSuccess("<math>\n</math>", "", .@"inline");
//     try expectSuccess("<math display=\"block\">\n</math>", "", .display);
// }

// test "variable" {
//     try expectSuccess("<math>\n<mi>x</mi>\n</math>", "x", .@"inline");
//     try expectSuccess("<math display=\"block\">\n</math>", "", .display);
// }
