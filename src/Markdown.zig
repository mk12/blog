// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Scanner = @import("Scanner.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Markdown = @This();

source: []const u8,
filename: []const u8,
location: Location,
summary_only: bool = false,

const TokenKind = enum {
    // Raw text or HTML.
    text,
    // Special
    blank_line,
    code,
    code_block,
    // Block markers
    @"#",
    @">",
    @"-",
    @"1.",
    @"* * *",
    // Inline markers
    @"_",
    @"**",
    // Typography
    @"'",
    @"\"",
    @"--",
    @"...",
    // Links
    @"[",
    @"](?)",
    @"][?]",
    // Footnotes
    @"[^?]",
    // Definitions
    @"[?]:",
    @"[ ]: ?",
    // Images
    @"![?]",
    @"![ ](?)",
    // Tables
    @"|?|",
    @"|:-:|",
    end_of_tr,
    // TODO ::: verse
};

const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

const Tokenizer = struct {
    scanner: *Scanner,
    prev: TokenKind = .blank_line,

    fn init(scanner: *Scanner) Tokenizer {
        return Tokenizer{ .scanner = scanner };
    }

    fn next(self: *Tokenizer) !?Token {
        if (self.scanner.eof()) return null;
        switch (self.prev) {
            .blank_line => {
                if (self.scanner.location.column == 1) {}
            },
            else => {},
        }
        unreachable;
    }
};

fn expectTokens(expected: []const TokenKind, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = Tokenizer.init(&scanner);
    var actual = std.ArrayList(TokenKind).init(allocator);
    while (try tokenizer.next()) |token| try actual.append(token.kind);
    try testing.expectEqualSlices(TokenKind, expected, actual.items);
}

test "tokenize empty string" {
    try expectTokens(&[_]TokenKind{}, "");
}

test "tokenize text" {
    try expectTokens(&[_]TokenKind{.text}, "Hello world!");
}

pub fn render(self: Markdown, reporter: *Reporter, writer: anytype) !void {
    _ = reporter;
    try writer.writeAll("<!-- MARKDOWN -->");
    if (self.summary_only) {
        try writer.writeAll("<!-- summary -->\n");
    } else {
        try writer.writeAll(self.source);
    }
}

pub fn summary(self: Markdown) Markdown {
    var copy = self;
    copy.summary_only = true;
    return copy;
}
