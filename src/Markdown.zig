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

const Token = union(enum) {
    // Special
    blank_line,
    code: []const u8,
    code_block: []const u8,
    // Block markers
    @"#",
    @">",
    @"-",
    @"1.",
    @"* * *",
    // Inline markers
    underscore,
    @"**",
    // Typography
    @"'",
    @"\"",
    @"--",
    @"...",
    // Links
    @"[",
    @"](?)": []const u8,
    @"][?]": []const u8,
    // Footnotes
    @"[^?]": []const u8,
    // Definitions
    @"[?]: ?": struct { []const u8, []const u8 },
    // Images
    @"![?](?)": struct { []const u8, []const u8 },
    // Tables
    @"|",
    @"|:-:",
    end_of_tr,
    // TODO ::: verse
};

const TokenKind = std.meta.Tag(Token);

const Tokenizer = struct {
    prev: TokenKind = .blank_line,

    fn next(self: *Tokenizer, scanner: *Scanner) !?Token {
        _ = scanner;
        _ = self;
        unreachable;
        // if (scanner.eof()) return null;
        // const start = scanner.offset;
        // var end: usize = undefined;
        // var token: Token = undefined;
        // switch (self.prev) {
        //     .blank_line => {
        //         if (scanner.location.column == 1) {
        //             if (scanner.attempt("# ")) {
        //                 scanner.skipWhitespace();
        //                 return .{ scanner.source[start..], .@"#" };
        //             }
        //         }
        //     },
        //     else => {},
        // }
        // return .{ scanner.source[start..end], token };
    }
};

fn expectTokens(expected: []const TokenKind, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = Tokenizer{};
    var actual = std.ArrayList(TokenKind).init(allocator);
    while (try tokenizer.next(&scanner)) |token| try actual.append(token);
    try testing.expectEqualSlices(TokenKind, expected, actual.items);
}

test "tokenize empty string" {
    // try expectTokens(&[_]TokenKind{}, "");
}

test "tokenize text" {
    // try expectTokens(&[_]TokenKind{.text}, "Hello world!");
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
