// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module renders a subset of TeX to MathML.
//! It is driven one line at a time so that it can be used by the Markdown
//! renderer (where display math can be nested in blockquotes, for example).

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const MathML = @This();

active: bool = false,
kind: Kind = undefined,

pub const Kind = enum {
    @"inline",
    display,

    pub fn delimiter(self: Kind) []const u8 {
        return switch (self) {
            .@"inline" => "$",
            .display => "$$",
        };
    }
};

pub fn init(writer: anytype, kind: Kind) !MathML {
    switch (kind) {
        .@"inline" => try writer.writeAll("<math>\n"),
        .display => try writer.writeAll("<math display=\"block\">\n"),
    }
    return MathML{ .kind = kind };
}

pub fn render(self: *MathML, writer: anytype, scanner: *Scanner) !bool {
    _ = self;
    assert(!scanner.eof());
    while (scanner.next()) |char| switch (char) {
        '$' => return true,
        else => try writer.writeByte(char),
    };
    return false;
}

fn renderClose(self: *MathML, writer: anytype) !void {
    _ = self;
    try writer.writeAll("</math>");
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
    var math = try init(writer, kind);
    while (!scanner.eof()) _ = try math.render(writer, &scanner);
    try math.renderClose(writer);
    try testing.expectEqualStrings(expected_mathml, actual_mathml.items);
}

test "empty input" {
    try expectSuccess("<math>\n</math>", "", .@"inline");
    try expectSuccess("<math display=\"block\">\n</math>", "", .display);
}

// test "variable" {
//     try expectSuccess("<math>\n<mi>x</mi>\n</math>", "x", .@"inline");
//     try expectSuccess("<math display=\"block\">\n</math>", "", .display);
// }
