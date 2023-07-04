// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;

const Token = struct {
    value: TokenValue,
    offset: u32,
    location: Location,
};

const TokenValue = union(enum) {
    // Special
    text: []const u8,
    code: []const u8,
    code_block: struct { language: []const u8, code: []const u8 },
    inline_math: []const u8,
    display_math: []const u8,
    // Block markers
    new_paragraph,
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
    @"[?]: ?": struct { label: []const u8, url: []const u8 },
    // Images
    @"![?](?)": struct { alt: []const u8, url: []const u8 },
    // Tables
    @"|",
    @"|:-:",
    end_of_tr,
    // TODO ::: verse
};

const Tokenizer = struct {
    prev_kind: std.meta.Tag(TokenValue) = .new_paragraph,
    peeked: ?Token = null,

    // fn peek(self: *Tokenizer, scanner: *Scanner) !?Token {
    //     _ = scanner;
    //     _ = self;
    // }

    fn next(self: *Tokenizer, scanner: *Scanner) !?Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        const start_offset = scanner.offset;
        const start_location = scanner.location;
        const opt_token = try self.nextNonText(scanner);
        const end_offset = if (opt_token) |token| token.offset else scanner.offset;
        if (start_offset == end_offset) return opt_token;
        self.peeked = opt_token;
        return Token{
            .value = .{ .text = scanner.source[start_offset..end_offset] },
            .offset = @intCast(u32, start_offset),
            .location = start_location,
        };
    }

    fn nextNonText(self: *Tokenizer, scanner: *Scanner) !?Token {
        _ = self;
        if (scanner.eof()) return null;
        while (scanner.next()) |char| {
            _ = char;
        }
        return null;
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

fn expectTokens(expected: []const TokenValue, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = Tokenizer{};
    var actual = std.ArrayList(TokenValue).init(allocator);
    while (try tokenizer.next(&scanner)) |token| try actual.append(token.value);
    try testing.expectEqualDeep(expected, actual.items);
}

test "tokenize empty string" {
    try expectTokens(&[_]TokenValue{}, "");
}

test "tokenize text" {
    try expectTokens(&[_]TokenValue{.{ .text = "Hello world!" }}, "Hello world!");
}

test "tokenize inline" {
    try expectTokens(&[_]TokenValue{
        .underscore,
        .{ .text = "Hello" },
        .underscore,
        .{ .text = " " },
        .@"**",
        .{ .text = "world" },
        .@"**",
        .{ .text = "!" },
    },
        \\_Hello_ **world**!
    );
}

pub const Options = struct {
    is_inline: bool = false,
    first_paragraph_only: bool = false,
};

pub fn render(
    span: Span,
    filename: []const u8,
    options: Options,
    reporter: *Reporter,
    writer: anytype,
) !void {
    _ = options;
    var scanner = Scanner{
        .source = span.text,
        .reporter = reporter,
        .filename = filename,
        .location = span.location,
    };
    var tokenizer = Tokenizer{};
    try helper(&scanner, &tokenizer, writer);
    // args.first_paragraph_only
    // args.is_inline
}

fn helper(scanner: *Scanner, tokenizer: *Tokenizer, writer: anytype) !void {
    const token = (try tokenizer.next(scanner)).?;
    switch (token.value) {
        .text => |text| try writer.writeAll(text),
        else => {},
    }
}

// fn descend(self: Markdown, reporter: *Reporter, writer: anytype, comptime tag: []const u8) !void {
//     _ = reporter;
//     _ = self;
//     try writer.writeAll("<" ++ tag ++ ">");
//     try writer.writeAll("</" ++ tag ++ ">");
// }

fn expectRenderSuccess(expected_html: []const u8, input: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var actual_html = std.ArrayList(u8).init(allocator);
    const span = Span{ .text = input, .location = .{} };
    try render(span, "input.md", options, &reporter, actual_html.writer());
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectRenderFailure(expected_message: []const u8, input: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    const span = Span{ .text = input, .location = .{} };
    try reporter.expectFailure(
        expected_message,
        render(span, "input.md", options, &reporter, std.io.null_writer),
    );
}

test "render empty string" {
    try expectRenderSuccess("", "", .{});
    try expectRenderSuccess("", "", .{ .is_inline = true });
}

test "render text" {
    try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{});
    try expectRenderSuccess("Hello world!", "Hello world!", .{ .is_inline = true });
}
