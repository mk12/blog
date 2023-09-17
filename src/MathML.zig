// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module renders a subset of TeX to MathML.
//! It scans input until a closing "$" or "$$" delimiter, and it yields control
//! when it encounters a newline, so it can be used by the Markdown renderer.

const std = @import("std");
const fmt = std.fmt;
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
        .@"inline" => try writer.writeAll("<math>"),
        .display => try writer.writeAll("<math display=\"block\">"),
    }
    return MathML{ .kind = kind };
}

pub fn render(self: *MathML, writer: anytype, scanner: *Scanner) !bool {
    _ = self;
    // Challenges:
    // - know when to use mrow (don't if only 1)
    // - know when to use msup/msub (don't see ^ or _ at start)
    //   - well, need (...) or {...} to use it far away
    // - can yield at any moment... can't look ahead to find matching ),
    //   might be on another line after a blockquote >
    // - is this needlessly complicated when probably will not be used in blockquotes?
    // - more realistic would be adjusting to support loose lists, or hard wrapping
    assert(!scanner.eof());
    while (scanner.next()) |char| switch (char) {
        '$' => return true,
        '\\' => unreachable,
        '0'...'9' => unreachable, // <mn>
        '(', ')', '=' => try fmt.format(writer, "<mo>{c}</mo>", .{char}),
        else => try fmt.format(writer, "<mi>{c}</mi>", .{char}),
    };
    return false;
}

fn renderEnd(self: *MathML, writer: anytype) !void {
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
    try math.renderEnd(writer);
    try testing.expectEqualStrings(expected_mathml, actual_mathml.items);
}

test "empty input" {
    try expectSuccess("<math></math>", "", .@"inline");
    try expectSuccess("<math display=\"block\"></math>", "", .display);
}

test "variable" {
    try expectSuccess("<math><mi>x</mi></math>", "x", .@"inline");
    try expectSuccess("<math display=\"block\"><mi>x</mi></math>", "x", .display);
}
