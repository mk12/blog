// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements Markdown to HTML rendering. It is designed for speed:
//! it renders in a single pass and does not allocate any memory. Text that does
//! not need to be altered is memcpy'd straight to the output.
//!
//! To render a string, you also need a Context. You can obtain this by calling
//! parse, which just extracts the link reference definitions from the bottom.
//! You can then reuse this context to render different substrings in the file.
//!
//! It is not CommonMark compliant. It lacks a few regular Markdown features:
//! no hard wrapping (a single newline ends a paragraph), no nesting in lists,
//! no loose lists, no single-asterisk italics, and no double-underscore bold.
//! It only supports fenced code blocks, not indented ones. It requires link
//! references to be defined together at the end of the file, not in the middle.
//! It treats ![Foo](foo.jpg) syntax as a block <figure>, not an inline <img>.
//! The syntax ![^Foo](foo.jpg) puts the <figcaption> above instead of below.
//! It allows Markdown within raw HTML. It supports smart typography, auto
//! heading IDs, footnotes, code highlighting, tables, and TeX math in dollar
//! signs rendered to MathML.
//!
//! It is customizable with Options and with Hooks. The options are mostly
//! flags, e.g. whether to enable code highlighting. The hooks allow you to
//! rewrite URLs in links and to override how images are rendered. The hooks
//! also allow handling of <template src="..."/> and <template>...</template>
//! directives, which fail by default otherwise.

const std = @import("std");
const testing = std.testing;
const tag_stack = @import("tag_stack.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Highlighter = @import("Highlighter.zig");
const Language = Highlighter.Language;
const MathML = @import("MathML.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const TagStack = tag_stack.TagStack;
const Markdown = @This();

text: []const u8,
context: Context,

pub const Context = struct {
    source: []const u8,
    filename: []const u8,
    links: LinkMap,
};

pub const LinkMap = std.StringHashMapUnmanaged([]const u8);

pub fn parse(allocator: Allocator, scanner: *Scanner) !Markdown {
    var links = LinkMap{};
    const start = scanner.offset;
    scanner.offset = scanner.source.len;
    const end = while (true) {
        while (scanner.offset > start and scanner.prev(0) == '\n') scanner.uneat();
        const end = scanner.offset;
        while (scanner.offset > start and scanner.prev(0) != '\n') scanner.uneat();
        const start_of_line = scanner.offset;
        if (!scanner.consume('[')) break end;
        if (scanner.consume('^')) break end;
        const label = scanner.consumeLineUntil(']') orelse break end;
        if (!scanner.consumeString(": ")) break end;
        try links.put(allocator, label, scanner.source[scanner.offset..end]);
        scanner.offset = start_of_line;
    };
    return Markdown{
        .text = scanner.source[start..end],
        .context = Context{ .source = scanner.source, .filename = scanner.filename, .links = links },
    };
}

test "parse" {
    const source =
        \\This is the body.
        \\
        \\[This is not a link]
        \\[foo]: foo link
        \\[bar baz]: bar baz link
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter, .filename = "test.md" };
    const md = try parse(allocator, &scanner);
    try testing.expectEqualStrings(
        \\This is the body.
        \\
        \\[This is not a link]
    , md.text);
    try testing.expectEqualStrings(source, md.context.source);
    try testing.expectEqualStrings("test.md", md.context.filename);
    try testing.expectEqual(@as(usize, 2), md.context.links.size);
    try testing.expectEqualStrings("foo link", md.context.links.get("foo").?);
    try testing.expectEqualStrings("bar baz link", md.context.links.get("bar baz").?);
}

test "parse with gaps between link definitions" {
    const source =
        \\This is the body.
        \\
        \\[foo]: foo link
        \\
        \\[bar baz]: bar baz link
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const md = try parse(allocator, &scanner);
    try testing.expectEqualStrings("This is the body.", md.text);
    try testing.expectEqual(@as(usize, 2), md.context.links.size);
    try testing.expectEqualStrings("foo link", md.context.links.get("foo").?);
    try testing.expectEqualStrings("bar baz link", md.context.links.get("bar baz").?);
}

const Token = union(enum) {
    // Special tokens
    eof,
    @"\n",

    // Blocks tokens
    @"#": u8,
    @"-",
    @"1.",
    @">",
    @"* * *\n",
    @"```x\n": []const u8,
    @"$$",
    @"![](x)": []const u8, // can also be inline
    @"![][x]": []const u8, // can also be inline
    @"![...](x)": []const u8,
    @"![...][x]": []const u8,
    @"![^",
    @"[^x]: ": []const u8,
    @"| ",
    @"<template>\n",
    @"<template src=.../>\n": []const u8,
    @"<toc/>\n",

    // Inline tokens
    text: []const u8,
    @"<",
    @"&",
    @"\\x": u8,
    @"[^x]": []const u8,
    _,
    @"**",
    @"`",
    @"$",
    @"[...](x)": []const u8,
    @"[...][x]": []const u8,
    @" | ",
    lsquo,
    rsquo,
    ldquo,
    rdquo,
    @"--",
    @"...",
    @"<template>",
    @"<template src=.../>": []const u8,

    // Neither block nor inline
    @"]",
    @"](x)": []const u8,
    @"][x]": []const u8,

    fn linkish(url_or_label: []const u8, args: struct { bang: bool, empty: bool, square: bool }) Token {
        return switch (args.bang) {
            false => if (args.square) .{ .@"[...][x]" = url_or_label } else .{ .@"[...](x)" = url_or_label },
            true => switch (args.empty) {
                false => if (args.square) .{ .@"![...][x]" = url_or_label } else .{ .@"![...](x)" = url_or_label },
                true => if (args.square) .{ .@"![][x]" = url_or_label } else .{ .@"![](x)" = url_or_label },
            },
        };
    }

    fn isInline(self: Token) bool {
        return @intFromEnum(self) >= @intFromEnum(Token.text);
    }
};

// Note: The tokenizer is currently infallible. It might be worth changing it to
// be fallible, that way it could be stricter and reveal more problems.
const Tokenizer = struct {
    scanner: *Scanner,
    token_start: usize,
    in_raw_html_block: bool = false,
    peeked: ?struct { token: Token, token_start: usize, in_raw_html_block: bool } = null,

    // Be careful reading these values outside the Tokenizer, since they might
    // pertain to the peeked token, not the current one.
    block_allowed: bool = true,
    in_inline_code: bool = false,
    in_top_caption_figure: bool = false,
    link_depth: u8 = 0,

    fn init(scanner: *Scanner) !Tokenizer {
        scanner.skipMany('\n');
        return Tokenizer{ .scanner = scanner, .token_start = scanner.offset };
    }

    fn takeScanner(self: Tokenizer) *Scanner {
        assert(self.peeked == null);
        return self.scanner;
    }

    fn fail(self: Tokenizer, comptime format: []const u8, args: anytype) Reporter.Error {
        return self.scanner.failAtOffset(self.token_start, format, args);
    }

    fn tokenStartPtr(self: Tokenizer) [*]const u8 {
        return self.scanner.source.ptr + self.token_start;
    }

    fn remaining(self: Tokenizer) []const u8 {
        assert(self.peeked == null);
        return self.scanner.source[self.scanner.offset..];
    }

    fn next(self: *Tokenizer) Token {
        if (self.peeked) |peeked| {
            self.peeked = null;
            self.token_start = peeked.token_start;
            self.in_raw_html_block = peeked.in_raw_html_block;
            return peeked.token;
        }
        const start = self.scanner.offset;
        const in_raw_html_block = self.in_raw_html_block;
        const token = self.nextNonText();
        const text = self.scanner.source[start..@max(start, self.token_start)];
        if (text.len == 0) return token;
        self.peeked = .{ .token = token, .token_start = self.token_start, .in_raw_html_block = self.in_raw_html_block };
        self.token_start = start;
        self.in_raw_html_block = in_raw_html_block;
        return Token{ .text = text };
    }

    fn nextNonText(self: *Tokenizer) Token {
        if (self.block_allowed) {
            self.block_allowed = false;
            const start = self.scanner.offset;
            if (self.recognizeBlock()) |token| return token;
            self.scanner.offset = start;
        }
        if (self.in_inline_code) while (true) if (self.recognizeInsideInlineCode()) |token| return token;
        while (true) if (self.recognizeInline()) |token| return token;
    }

    fn recognizeBlock(self: *Tokenizer) ?Token {
        const scanner = self.scanner;
        self.token_start = scanner.offset;
        switch (scanner.next() orelse return .eof) {
            '#' => {
                const level: u8 = @intCast(1 + scanner.consumeMany('#'));
                if (level <= 6 and scanner.consume(' ')) return .{ .@"#" = level };
            },
            '<' => {
                if (scanner.consumeString("template")) {
                    if (scanner.consumeStringEol(">")) {
                        self.block_allowed = true;
                        return .@"<template>\n";
                    }
                    blk: {
                        if (!scanner.consumeString(" src=\"")) break :blk;
                        const src = scanner.consumeLineUntil('"') orelse break :blk;
                        if (!scanner.consumeStringEol("/>")) break :blk;
                        self.block_allowed = true;
                        return .{ .@"<template src=.../>\n" = src };
                    }
                    scanner.offset = self.token_start + 1;
                } else if (scanner.consumeStringEol("toc/>")) {
                    _ = self.recognizeAfterNewline();
                    self.block_allowed = true;
                    return .@"<toc/>\n";
                }
                if (scanner.next()) |char| switch (char) {
                    '/', '?', '!', 'a'...'z' => {
                        if ((char == '!' and scanner.consumeString("--") and scanner.consumeUntilString("-->") != null) or
                            (scanner.consumeLineUntilClose('<', '>') != null and scanner.peekEol()))
                        {
                            self.in_raw_html_block = true;
                            // We can't just return null here (as we do for raw inline HTML)
                            // because `in_raw_html_block` needs to apply to this token.
                            return .{ .text = scanner.source[self.token_start..scanner.offset] };
                        }
                    },
                    else => {},
                };
            },
            '>' => if (scanner.consume(' ') or scanner.peekEol()) {
                self.block_allowed = true;
                return .@">";
            },
            '`' => if (scanner.consumeString("``")) {
                self.block_allowed = true;
                return .{ .@"```x\n" = scanner.consumeUntilEol() };
            },
            '$' => if (scanner.consume('$')) return .@"$$",
            '-' => if (scanner.consume(' ')) return .@"-",
            '1'...'9' => while (scanner.next()) |char| switch (char) {
                '0'...'9' => {},
                '.' => if (scanner.next() == ' ') return .@"1.",
                else => break,
            },
            '*' => if (scanner.consumeStringEol(" * *")) {
                _ = self.recognizeAfterNewline();
                return .@"* * *\n";
            },
            '|' => {
                scanner.skipMany(' ');
                // Skip over | --- | --- | row.
                const offset = scanner.offset;
                if (scanner.consume('-')) {
                    _ = scanner.consumeWhileAny(" |-");
                    if (scanner.consumeString("\n|")) {
                        scanner.skipMany(' ');
                        return .@"| ";
                    }
                }
                scanner.offset = offset;
                return .@"| ";
            },
            '[' => if (scanner.consume('^')) if (scanner.consumeLineUntil(']')) |label|
                if (scanner.consume(':')) {
                    scanner.skipMany(' ');
                    return .{ .@"[^x]: " = label };
                },
            else => {},
        }
        return null;
    }

    fn recognizeInsideInlineCode(self: *Tokenizer) ?Token {
        const scanner = self.scanner;
        self.token_start = scanner.offset;
        switch (scanner.next() orelse return .eof) {
            '\n' => return self.recognizeAfterNewline(),
            '`' => {
                self.in_inline_code = false;
                return .@"`";
            },
            '<' => return .@"<",
            '&' => return .@"&",
            else => return null,
        }
    }

    fn recognizeInline(self: *Tokenizer) ?Token {
        const scanner = self.scanner;
        self.token_start = scanner.offset;
        switch (scanner.next() orelse return .eof) {
            '\n' => return self.recognizeAfterNewline(),
            '`' => {
                self.in_inline_code = true;
                return .@"`";
            },
            '<' => {
                if (scanner.consumeString("template")) {
                    if (scanner.consume('>')) return .@"<template>";
                    blk: {
                        if (!scanner.consumeString(" src=\"")) break :blk;
                        const src = scanner.consumeLineUntil('"') orelse break :blk;
                        if (!scanner.consumeString("/>")) break :blk;
                        return .{ .@"<template src=.../>" = src };
                    }
                    scanner.offset = self.token_start + 1;
                }
                if (scanner.peek()) |char| switch (char) {
                    '/', '?', 'a'...'z' => if (scanner.consumeLineUntilClose('<', '>')) |_| return null,
                    '!' => if (scanner.consumeString("!--") and scanner.consumeUntilString("-->") != null) return null,
                    else => {},
                };
                return .@"<";
            },
            '\\' => if (scanner.next()) |char| return .{ .@"\\x" = char },
            '$' => return .@"$",
            '!' => if (scanner.consume('['))
                if (self.recognizeAfterOpenBracket(.figure)) |token| return token,
            '[' => return self.recognizeAfterOpenBracket(.link),
            ']' => {
                if (self.link_depth == 0) {
                    if (!self.in_top_caption_figure) return null;
                    self.in_top_caption_figure = false;
                    if (scanner.consume('(')) if (scanner.consumeLineUntil(')')) |url| return .{ .@"](x)" = url };
                    if (scanner.consume('[')) if (scanner.consumeLineUntil(']')) |label| return .{ .@"][x]" = label };
                    return .{ .@"](x)" = "" };
                }
                self.link_depth -= 1;
                if (scanner.peek()) |char| switch (char) {
                    '(' => _ = scanner.consumeLineUntil(')').?,
                    '[' => _ = scanner.consumeLineUntil(']').?,
                    else => {},
                };
                return .@"]";
            },
            '*' => if (scanner.consume('*')) return .@"**",
            '_' => return ._,
            '\'' => {
                const prev = scanner.prev(1);
                return if (prev == null or prev == ' ' or prev == '\n' or prev == '(' or prev == '[') .lsquo else .rsquo;
            },
            '"' => {
                const prev = scanner.prev(1);
                return if (prev == null or prev == ' ' or prev == '\n' or prev == '(' or prev == '[') .ldquo else .rdquo;
            },
            '-' => if (scanner.consume('-')) return .@"--",
            ' ' => {
                scanner.skipMany(' ');
                if (scanner.consume('|')) return self.recognizeAfterPipe();
            },
            '|' => return self.recognizeAfterPipe(),
            '.' => if (scanner.consumeString("..")) return .@"...",
            else => {},
        }
        return null;
    }

    fn recognizeAfterNewline(self: *Tokenizer) Token {
        if (self.scanner.peekEol()) self.in_raw_html_block = false;
        self.block_allowed = true;
        return .@"\n";
    }

    fn recognizeAfterPipe(self: *Tokenizer) Token {
        const scanner = self.scanner;
        scanner.skipMany(' ');
        if (scanner.eof()) return .eof;
        if (scanner.consume('\n')) return self.recognizeAfterNewline();
        return .@" | ";
    }

    fn recognizeAfterOpenBracket(self: *Tokenizer, kind: enum { link, figure }) ?Token {
        const scanner = self.scanner;
        if (scanner.consume('^')) return switch (kind) {
            .link => if (scanner.consumeLineUntil(']')) |label| .{ .@"[^x]" = label } else null,
            .figure => {
                self.in_top_caption_figure = true;
                return .@"![^";
            },
        };
        const start_bracketed = scanner.offset;
        var go_back = true;
        defer if (go_back) {
            scanner.offset = start_bracketed;
        };
        var escaped = false;
        var in_code = false;
        var depth: usize = 1;
        while (true) {
            const char = scanner.next() orelse return null;
            if (char == '\n') return null;
            if (escaped) {
                escaped = false;
            } else if (in_code) {
                if (char == '`') in_code = false;
            } else switch (char) {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                '\\' => escaped = true,
                '`' => in_code = true,
                else => {},
            }
        }
        const bang = kind == .figure;
        const end_bracketed = scanner.offset - 1;
        const empty = start_bracketed == end_bracketed;
        const closing_char: u8 = blk: {
            if (scanner.next()) |char| switch (char) {
                '(' => break :blk ')',
                '[' => break :blk ']',
                else => {},
            };
            // Shortcut reference link.
            const label = scanner.source[start_bracketed..end_bracketed];
            self.link_depth += 1;
            return Token.linkish(label, .{ .bang = bang, .empty = empty, .square = true });
        };
        const url_or_label = scanner.consumeLineUntil(closing_char) orelse return null;
        self.link_depth += 1;
        const token = Token.linkish(url_or_label, .{ .bang = bang, .empty = empty, .square = closing_char == ']' });
        if (token == .@"![](x)" or token == .@"![][x]") go_back = false;
        return token;
    }
};

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Tag = std.meta.Tag(Token);
    const expected_tags = try allocator.alloc(Tag, expected.len);
    for (expected_tags, expected) |*tag, token| tag.* = token;
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = try Tokenizer.init(&scanner);
    var actual: std.ArrayList(Token) = .empty;
    var actual_tags: std.ArrayList(Tag) = .empty;
    while (true) {
        const token = tokenizer.next();
        try actual.append(allocator, token);
        try actual_tags.append(allocator, token);
        if (token == .eof) break;
    }
    try testing.expectEqualSlices(Tag, expected_tags, actual_tags.items);
    try testing.expectEqualDeep(expected, actual.items);
}

test "tokenize empty string" {
    try expectTokens(&[_]Token{.eof}, "");
}

test "tokenize text" {
    try expectTokens(&[_]Token{ .{ .text = "Hello world!" }, .eof }, "Hello world!");
}

test "tokenize inline" {
    try expectTokens(&[_]Token{
        ._,
        .{ .text = "Hello" },
        ._,
        .{ .text = " " },
        .@"**",
        .{ .text = "world" },
        .@"**",
        .{ .text = " " },
        .@"`",
        .{ .text = "x" },
        .@"&",
        .{ .text = "y" },
        .@"`",
        .{ .text = "!<br>" },
        .eof,
    },
        \\_Hello_ **world** `x&y`!<br>
    );
}

test "tokenize block" {
    try expectTokens(&[_]Token{
        .{ .@"#" = 1 },
        .{ .text = "The " },
        ._,
        .{ .text = "heading" },
        ._,
        .@"\n",
        .@"\n",
        .@">",
        .@"-",
        .{ .text = "A " },
        .@"`",
        .{ .text = "list" },
        .@"`",
        .{ .text = " in a quote." },
        .@"\n",
        .@">",
        .@"\n",
        .@">",
        .@"* * *\n",
        .eof,
    },
        \\# The _heading_
        \\
        \\> - A `list` in a quote.
        \\>
        \\> * * *
    );
}

test "tokenize inline link" {
    try expectTokens(&[_]Token{
        .{ .@"[...](x)" = "bar" },
        .{ .text = "foo" },
        .@"]",
        .eof,
    },
        \\[foo](bar)
    );
}

test "tokenize figure" {
    try expectTokens(&[_]Token{
        .{ .@"![...](x)" = "bar" },
        .{ .text = "Foo" },
        .@"]",
        .@"\n",
        .{ .@"![...][x]" = "bar" },
        .{ .text = "Foo" },
        .@"]",
        .eof,
    },
        \\![Foo](bar)
        \\![Foo][bar]
    );
}

test "tokenize figure without caption" {
    try expectTokens(&[_]Token{
        .{ .@"![](x)" = "bar" },
        .@"\n",
        .{ .@"![][x]" = "bar" },
        .eof,
    },
        \\![](bar)
        \\![][bar]
    );
}

test "tokenize table" {
    try expectTokens(&[_]Token{
        .@"| ",
        .{ .text = "Fruit" },
        .@" | ",
        .{ .text = "Color" },
        .@"\n",
        .@"| ",
        .{ .text = "Apple" },
        .@" | ",
        .{ .text = "Red" },
        .eof,
    },
        \\| Fruit | Color |
        \\| Apple | Red |
    );
}

test "tokenize toc" {
    try expectTokens(&[_]Token{ .@"<toc/>\n", .eof }, "<toc/>");
}

test "tokenize block template with src" {
    try expectTokens(&[_]Token{ .{ .@"<template src=.../>\n" = "foo" }, .eof },
        \\<template src="foo"/>
    );
}

test "tokenize block template without src" {
    try expectTokens(&[_]Token{ .@"<template>\n", .eof },
        \\<template>
    );
}

test "tokenize inline template with src" {
    try expectTokens(&[_]Token{ .@"-", .{ .@"<template src=.../>" = "foo" }, .eof },
        \\- <template src="foo"/>
    );
}

test "tokenize inline template without src" {
    try expectTokens(&[_]Token{ .@"-", .@"<template>", .eof },
        \\- <template>
    );
}

test "tokenize two block templates" {
    try expectTokens(&[_]Token{
        .{ .@"<template src=.../>\n" = "a" },
        .{ .@"<template src=.../>\n" = "b" },
        .eof,
    },
        \\<template src="a"/>
        \\<template src="b"/>
    );
}

pub const Options = struct {
    is_inline: bool = false,
    first_block_only: bool = false,
    highlight_code: bool = false,
    auto_heading_ids: bool = false,
    shift_heading_level: i8 = 0,
    out_has_footnotes: ?*bool = null,
    hook_options: ?*const anyopaque = null,
};

pub const ImageInfo = struct {
    width: []const u8,
    height: []const u8,
    lazy: bool,
};

fn WithDefaultHooks(comptime Inner: type) type {
    return struct {
        const Underlying = switch (@typeInfo(Inner)) {
            .pointer => |info| info.childe,
            else => Inner,
        };
        inner: Inner,

        fn writeUrl(self: @This(), writer: *std.Io.Writer, context: HookContext, url: []const u8) !void {
            if (@hasDecl(Underlying, "writeUrl")) return self.inner.writeUrl(writer, context, url);
            try writer.writeAll(url);
        }

        fn writeImage(self: @This(), writer: *std.Io.Writer, context: HookContext, url: []const u8, info: ?ImageInfo) !void {
            if (@hasDecl(Underlying, "writeImage")) return self.inner.writeImage(writer, context, url, info);
            try writer.print("<img src=\"{s}\"", .{url});
            if (info) |i| {
                try writer.print(" width=\"{s}\" height=\"{s}\"", .{ i.width, i.height });
                if (i.lazy) try writer.writeAll(" loading=\"lazy\"");
            }
            try writer.writeByte('>');
        }

        fn renderTemplate(self: @This(), writer: *std.Io.Writer, context: HookContext, name: []const u8) !void {
            if (@hasDecl(Underlying, "renderTemplate")) return self.inner.renderTemplate(writer, context, name) catch |err| {
                if (err == error.ErrorWasReported) context.addNote("template \"{s}\" executed here", .{name});
                return err;
            };
            return context.fail("no hook installed for renderTemplate", .{});
        }

        fn parseAndRenderTemplate(self: @This(), writer: *std.Io.Writer, context: HookContext, scanner: *Scanner) !void {
            if (@hasDecl(Underlying, "parseAndRenderTemplate")) return self.inner.parseAndRenderTemplate(writer, context, scanner) catch |err| {
                if (err == error.ErrorWasReported) context.addNote("executing template starting here", .{});
                return err;
            };
            return context.fail("no hook installed for parseAndRenderTemplate", .{});
        }
    };
}

const HookContextBuilder = struct {
    reporter: *Reporter,
    options: Options,
    source: []const u8,
    filename: []const u8,

    fn at(self: HookContextBuilder, ptr: [*]const u8) HookContext {
        return HookContext{ .reporter = self.reporter, .options = self.options, .source = self.source, .filename = self.filename, .ptr = ptr };
    }
};

pub const HookContext = struct {
    reporter: *Reporter,
    options: Options,
    source: []const u8,
    filename: []const u8,
    ptr: [*]const u8,

    pub fn fail(self: HookContext, comptime format: []const u8, args: anytype) Reporter.Error {
        return self.reporter.fail(self.filename, Location.fromPtr(self.source, self.ptr), format, args);
    }

    pub fn addNote(self: HookContext, comptime format: []const u8, args: anytype) void {
        self.reporter.addNote(self.filename, Location.fromPtr(self.source, self.ptr), format, args);
    }
};

pub fn render(self: Markdown, reporter: *Reporter, writer: *std.Io.Writer, hooks: anytype, options: Options) !void {
    const offset = self.text.ptr - self.context.source.ptr;
    var scanner = Scanner{
        .source = self.context.source[0 .. offset + self.text.len],
        .reporter = reporter,
        .filename = self.context.filename,
        .offset = offset,
    };
    var tokenizer = try Tokenizer.init(&scanner);
    const full_hooks = WithDefaultHooks(@TypeOf(hooks)){ .inner = hooks };
    const hook_ctx = HookContextBuilder{ .reporter = reporter, .source = self.context.source, .filename = self.context.filename, .options = options };
    return renderImpl(&tokenizer, writer, full_hooks, hook_ctx, self.context.links, options) catch |err| switch (err) {
        error.ExceededMaxTagDepth => return tokenizer.fail("exceeded maximum tag depth ({})", .{tag_stack.max_depth}),
        else => return err,
    };
}

const BlockTag = union(enum) {
    p,
    li,
    // I'm making this fit in 16 bytes just because I can.
    h: struct { source: ?[*]const u8, source_len: u32, level: u8 },
    ul,
    ol,
    blockquote,
    figure,
    figcaption,
    table,
    tr,
    th,
    td,
    footnote_ol: []const u8,
    footnote_li: []const u8,

    fn heading(source: []const u8, level: u8, options: Options) BlockTag {
        const shifted = @as(i8, @intCast(level)) + options.shift_heading_level;
        return BlockTag{
            .h = .{
                .source = if (options.auto_heading_ids) source.ptr else null,
                .source_len = @intCast(source.len),
                .level = @intCast(std.math.clamp(shifted, 1, 6)),
            },
        };
    }

    fn implicitChild(parent: ?BlockTag) ?BlockTag {
        return switch (parent orelse return .p) {
            .p, .li, .figure, .table, .tr, .footnote_li => unreachable,
            .h, .figcaption, .th, .td => null,
            .ul, .ol => .li,
            .blockquote => .p,
            .footnote_ol => |label| .{ .footnote_li = label },
        };
    }

    fn canContainBlankLinkes(self: BlockTag) bool {
        return switch (self) {
            .ul, .ol, .footnote_ol => true,
            else => false,
        };
    }

    fn goesOnItsOwnLine(self: BlockTag) bool {
        return switch (self) {
            .p, .li, .h, .figcaption, .tr, .th, .td, .footnote_li => false,
            .ul, .ol, .blockquote, .figure, .table, .footnote_ol => true,
        };
    }

    fn canContainBlock(self: BlockTag) bool {
        return self == .blockquote;
    }

    pub fn writeOpenTag(self: BlockTag, writer: *std.Io.Writer) !void {
        switch (self) {
            .h => |h| if (h.source) |source_ptr| {
                try writer.print("<h{} id=\"", .{h.level});
                _ = try generateAutoIdUntilNewline(writer, source_ptr[0..h.source_len]);
                try writer.writeAll("\">");
            } else {
                try writer.print("<h{}>", .{h.level});
            },
            .footnote_ol => try writer.writeAll("<hr class=\"footnotes-rule\">\n<ol class=\"footnotes\">"),
            .footnote_li => |label| try writer.print("<li id=\"fn:{s}\">", .{label}),
            else => try writer.print("<{t}>", .{self}),
        }
        if (self.goesOnItsOwnLine()) try writer.writeByte('\n');
    }

    pub fn writeCloseTag(self: BlockTag, writer: *std.Io.Writer) !void {
        if (self.goesOnItsOwnLine()) try writer.writeByte('\n');
        switch (self) {
            .h => |h| try writer.print("</h{}>", .{h.level}),
            .footnote_ol => try writer.writeAll("</ol>"),
            .footnote_li => |label| try writer.print("&nbsp;<a href=\"#fnref:{s}\">↩︎</a></li>", .{label}),
            else => try writer.print("</{t}>", .{self}),
        }
    }
};

const InlineTag = enum {
    i,
    b,
    code,
    a,

    pub fn writeOpenTag(self: InlineTag, writer: *std.Io.Writer) !void {
        try writer.print("<{t}>", .{self});
    }

    pub fn writeCloseTag(self: InlineTag, writer: *std.Io.Writer) !void {
        try writer.print("</{t}>", .{self});
    }
};

fn generateAutoIdUntilNewline(writer: *std.Io.Writer, source: []const u8) !usize {
    var mode: union(enum) { normal, ignore_until: u8 } = .normal;
    var pending: enum { start, none, hyphen } = .start;
    for (source, 0..) |char, i| switch (mode) {
        .normal => switch (char) {
            '\n' => return i,
            '\'' => {},
            'A'...'Z', 'a'...'z', '0'...'9' => {
                if (pending == .hyphen) try writer.writeByte('-');
                pending = .none;
                try writer.writeByte(std.ascii.toLower(char));
            },
            else => {
                if (char == ']' and i < source.len - 1) switch (source[i + 1]) {
                    '(' => mode = .{ .ignore_until = ')' },
                    '[' => mode = .{ .ignore_until = ']' },
                    else => {},
                };
                if (pending == .none) pending = .hyphen;
            },
        },
        .ignore_until => |delim| if (char == delim) {
            mode = .normal;
        },
    };
    return source.len;
}

const UrlInfo = struct {
    url: []const u8,
    image: ?ImageInfo = null,
    class: ?[]const u8 = null,
};

fn lookupUrl(scanner: *Scanner, links: LinkMap, url_or_label: []const u8, tag: std.meta.Tag(Token)) !UrlInfo {
    const url_text = switch (tag) {
        .@"[...](x)", .@"![](x)", .@"![...](x)", .@"](x)" => url_or_label,
        .@"[...][x]", .@"![][x]", .@"![...][x]", .@"][x]" => links.get(url_or_label) orelse
            return scanner.failAtPtr(url_or_label.ptr, "link label '{s}' is not defined", .{url_or_label}),
        else => unreachable,
    };
    const index = std.mem.findScalar(u8, url_text, ' ') orelse return UrlInfo{ .url = url_text };
    switch (tag) {
        .@"[...](x)", .@"[...][x]", .@"](x)", .@"][x]" => return scanner.failAtPtr(url_or_label.ptr + index, "unexpected space", .{}),
        else => {},
    }
    const offset = url_text.ptr - scanner.source.ptr;
    var new_scanner = Scanner{
        .source = scanner.source.ptr[0 .. offset + url_text.len],
        .reporter = scanner.reporter,
        .filename = scanner.filename,
        .offset = offset + index + 1,
    };
    try new_scanner.expect('"');
    const width = new_scanner.consumeWhileAny("0123456789.");
    try new_scanner.expect('x');
    const height = new_scanner.consumeWhileAny("0123456789.");
    const lazy = new_scanner.consumeString(" lazy");
    const image = ImageInfo{ .width = width, .height = height, .lazy = lazy };
    const class = if (new_scanner.consume(' ')) blk: {
        try new_scanner.expect('.');
        break :blk new_scanner.consumeLineUntil('"') orelse return new_scanner.fail("expected closing '\"'", .{});
    } else blk: {
        try new_scanner.expect('"');
        break :blk null;
    };
    return UrlInfo{ .url = url_text[0..index], .image = image, .class = class };
}

const Mode = union(enum) {
    code: Highlighter,
    math: MathML,

    fn @"resume"(self: *Mode, writer: *std.Io.Writer, scanner: *Scanner) !bool {
        return switch (self.*) {
            inline else => |*mode| mode.@"resume"(writer, scanner),
        };
    }

    fn consumesFinalEol(self: Mode) bool {
        return switch (self) {
            .code => true,
            .math => false,
        };
    }

    fn terminator(self: Mode) []const u8 {
        return switch (self) {
            .code => Highlighter.terminator,
            .math => |math| math.delimiter(),
        };
    }
};

fn pushFigure(writer: *std.Io.Writer, blocks: *TagStack(BlockTag), opt_class: ?[]const u8) !void {
    const class = opt_class orelse return blocks.push(writer, .figure);
    try writer.print("<figure class=\"{s}\">\n", .{class});
    try blocks.pushWithoutWriting(.figure);
}

fn renderImpl(tokenizer: *Tokenizer, writer: *std.Io.Writer, hooks: anytype, hook_ctx: HookContextBuilder, links: LinkMap, options: Options) !void {
    var blocks = TagStack(BlockTag){};
    var inlines = TagStack(InlineTag){};
    var active_mode: ?Mode = null;
    var first_iteration = true;
    while (true) {
        var num_blocks_open: usize = 0;
        const unconsumed_token = while (num_blocks_open < blocks.len) : (num_blocks_open += 1) {
            const block = blocks.getPtr(num_blocks_open);
            switch (block.*) {
                .p, .li, .h, .figure, .figcaption, .tr, .th, .td, .footnote_li => break null,
                else => {},
            }
            const token = tokenizer.next();
            if (token == .@"\n" and block.*.canContainBlankLinkes()) {
                num_blocks_open += 1;
                break token;
            }
            switch (block.*) {
                .p, .li, .h, .figure, .figcaption, .tr, .th, .td, .footnote_li => unreachable,
                .ul => if (token != .@"-") break token,
                .ol => if (token != .@"1.") break token,
                .blockquote => if (token != .@">") break token,
                .table => if (token != .@"| ") break token,
                .footnote_ol => |*current_label| switch (token) {
                    .@"[^x]: " => |label| current_label.* = label,
                    else => break token,
                },
            }
        } else null;
        if (active_mode) |*mode| {
            if (unconsumed_token) |_| return tokenizer.fail("missing closing {s}", .{mode.terminator()});
            const scanner = tokenizer.takeScanner();
            if (scanner.eof()) break;
            const finished = try mode.@"resume"(writer, scanner);
            if (finished) active_mode = null;
            if (!finished or mode.consumesFinalEol()) continue;
        }
        var token = unconsumed_token orelse tokenizer.next();
        if (token == .eof) break;
        try blocks.truncate(writer, num_blocks_open);
        if (token == .@"\n") continue;
        if (!first_iteration) try writer.writeByte('\n');
        first_iteration = false;
        if (blocks.top()) |block| if (block == .table) try blocks.append(writer, &.{ .tr, .td });
        var need_implicit_block = !options.is_inline;
        while (true) {
            if (need_implicit_block and token.isInline()) {
                if (!(tokenizer.in_raw_html_block and blocks.len == 0))
                    if (BlockTag.implicitChild(blocks.top())) |block|
                        try blocks.push(writer, block);
                need_implicit_block = false;
            }
            switch (token) {
                // Line-ending tokens (must break)
                .eof, .@"\n" => break,
                .@"* * *\n" => break try writer.writeAll("<hr>"),
                .@"```x\n" => |language_str| {
                    const language = if (options.highlight_code) Language.from(language_str) else null;
                    active_mode = .{ .code = try Highlighter.render(writer, language) };
                    break;
                },
                .@"<template>\n" => {
                    assert(blocks.len == 0);
                    const ctx = hook_ctx.at(tokenizer.tokenStartPtr());
                    const scanner = tokenizer.takeScanner();
                    const start = scanner.offset;
                    const close_tag = "</template>";
                    const src = scanner.consumeUntilString(close_tag) orelse
                        return scanner.fail("encountered EOF while looking for \"</template>\"", .{});
                    const newline_before = scanner.prev(close_tag.len) == '\n';
                    const eol_after = scanner.eof() or scanner.consume('\n');
                    if (!newline_before or !eol_after)
                        return scanner.failAtOffset(scanner.offset - close_tag.len, "expected \"</template>\" to be on its own line", .{});
                    var template_scanner = scanner.*;
                    template_scanner.offset = start;
                    template_scanner.source = scanner.source[0 .. start + src.len];
                    try hooks.parseAndRenderTemplate(writer, ctx, &template_scanner);
                    break;
                },
                .@"<template src=.../>\n" => |src| {
                    const ctx = hook_ctx.at(tokenizer.tokenStartPtr());
                    try hooks.renderTemplate(writer, ctx, src);
                    break;
                },
                .@"<toc/>\n" => {
                    if (!options.auto_heading_ids) break;
                    try writer.print("<nav class=\"toc\">\n<h{0}>Contents</h{0}>\n<ul>\n", .{1 + options.shift_heading_level});
                    const scanner = tokenizer.takeScanner().*;
                    var offset = scanner.offset - 1;
                    const prefix = "\n# ";
                    while (std.mem.findPos(u8, scanner.source, offset, prefix)) |prefix_offset| {
                        try writer.writeAll("<li><a href=\"#");
                        const start = prefix_offset + prefix.len;
                        offset = start + try generateAutoIdUntilNewline(writer, scanner.source[start..]);
                        try writer.writeAll("\">");
                        var heading_scanner = scanner;
                        heading_scanner.offset = start;
                        heading_scanner.source.len = offset;
                        var heading_tokenizer = try Tokenizer.init(&heading_scanner);
                        try renderImpl(&heading_tokenizer, writer, hooks, hook_ctx, links, .{ .is_inline = true });
                        try writer.writeAll("</a></li>\n");
                    }
                    try writer.writeAll("</ul></nav>");
                    break;
                },
                // Common block tokens
                .@"#" => |level| try blocks.push(writer, BlockTag.heading(tokenizer.remaining(), level, options)),
                .@"-" => try blocks.push(writer, .ul),
                .@"1." => try blocks.push(writer, .ol),
                .@">" => try blocks.push(writer, .blockquote),
                // Common inline tokens
                .text => |text| try writer.writeAll(text),
                ._ => try inlines.toggle(writer, .i),
                .@"**" => try inlines.toggle(writer, .b),
                .@"`" => try inlines.toggle(writer, .code),
                // Math
                .@"$", .@"$$" => if (try MathML.render(writer, tokenizer.takeScanner(), .{ .block = token == .@"$$" })) |math| {
                    active_mode = .{ .math = math };
                    break;
                },
                // Footnotes
                .@"[^x]" => |number| if (!options.first_block_only) {
                    try writer.print(
                        \\<sup id="fnref:{0s}" class="fnref"><a href="#fn:{0s}">{0s}</a></sup>
                    , .{number});
                    if (options.out_has_footnotes) |out| out.* = true;
                },
                .@"[^x]: " => |label| try blocks.push(writer, .{ .footnote_ol = label }),
                // Links
                inline .@"[...](x)", .@"[...][x]" => |url_or_label, tag| {
                    const info = try lookupUrl(tokenizer.takeScanner(), links, url_or_label, tag);
                    try writer.writeAll("<a href=\"");
                    try hooks.writeUrl(writer, hook_ctx.at(info.url.ptr), info.url);
                    try writer.writeAll("\">");
                    try inlines.pushWithoutWriting(.a);
                },
                .@"]" => if (inlines.top() == .a) {
                    try inlines.pop(writer);
                } else if (blocks.top() != null and blocks.top().? == .figcaption) {
                    try blocks.popTag(writer, .figcaption);
                    try blocks.popTag(writer, .figure);
                } else {
                    return tokenizer.fail("unexpected \"]\"", .{});
                },
                // Figures
                inline .@"![](x)", .@"![][x]" => |url_or_label, tag| {
                    const info = try lookupUrl(tokenizer.takeScanner(), links, url_or_label, tag);
                    const figure = blocks.top() == null or blocks.top().?.canContainBlock();
                    if (figure) try pushFigure(writer, &blocks, info.class);
                    try hooks.writeImage(writer, hook_ctx.at(info.url.ptr), info.url, info.image);
                    if (figure) try blocks.popTag(writer, .figure);
                },
                inline .@"![...](x)", .@"![...][x]" => |url_or_label, tag| {
                    const info = try lookupUrl(tokenizer.takeScanner(), links, url_or_label, tag);
                    try pushFigure(writer, &blocks, info.class);
                    try hooks.writeImage(writer, hook_ctx.at(info.url.ptr), info.url, info.image);
                    try writer.writeByte('\n');
                    try blocks.push(writer, .figcaption);
                },
                .@"![^" => try blocks.append(writer, &.{ .figure, .figcaption }),
                inline .@"](x)", .@"][x]" => |url_or_label, tag| {
                    const info = try lookupUrl(tokenizer.takeScanner(), links, url_or_label, tag);
                    try blocks.popTag(writer, .figcaption);
                    try writer.writeByte('\n');
                    try hooks.writeImage(writer, hook_ctx.at(info.url.ptr), info.url, info.image);
                    try blocks.popTag(writer, .figure);
                },
                // Tables
                .@"| " => try blocks.append(writer, &.{ .table, .tr, .th }),
                .@" | " => {
                    const block = blocks.top().?;
                    assert(block == .td or block == .th);
                    try block.writeCloseTag(writer);
                    try block.writeOpenTag(writer);
                },
                // Escapes
                .@"\\x" => |char| try writer.writeByte(char),
                // HTML entities
                .@"<" => try writer.writeAll("&lt;"),
                .@"&" => try writer.writeAll("&amp;"),
                // Smart typography
                .lsquo => try writer.writeAll("‘"),
                .rsquo => try writer.writeAll("’"),
                .ldquo => try writer.writeAll("“"),
                .rdquo => try writer.writeAll("”"),
                .@"--" => try writer.writeAll("–"), // en dash
                .@"..." => try writer.writeAll("…"),
                // Inline templates
                .@"<template>" => {
                    const ctx = hook_ctx.at(tokenizer.tokenStartPtr());
                    const scanner = tokenizer.takeScanner();
                    const start = scanner.offset;
                    const src = scanner.consumeUntilString("</template>") orelse
                        return scanner.fail("encountered EOF while looking for \"</template>\"", .{});
                    var template_scanner = scanner.*;
                    template_scanner.offset = start;
                    template_scanner.source = scanner.source[0 .. start + src.len];
                    try hooks.parseAndRenderTemplate(writer, ctx, &template_scanner);
                },
                .@"<template src=.../>" => |src| {
                    const ctx = hook_ctx.at(tokenizer.tokenStartPtr());
                    try hooks.renderTemplate(writer, ctx, src);
                },
            }
            token = tokenizer.next();
        }
        if (inlines.top()) |tag| return tokenizer.fail("unclosed <{t}> tag", .{tag});
        if (options.first_block_only) break;
    }
    assert(inlines.len == 0);
    if (active_mode) |mode| return tokenizer.takeScanner().fail("missing closing {s}", .{mode.terminator()});
    try blocks.truncate(writer, 0);
}

fn expect(expected_html: []const u8, source: []const u8, options: Options) !void {
    try expectWithHooks(expected_html, source, options, .{});
}

fn expectWithHooks(expected_html: []const u8, source: []const u8, options: Options, hooks: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const markdown = try parse(allocator, &scanner);
    var actual_html: std.Io.Writer.Allocating = .init(allocator);
    try markdown.render(&reporter, &actual_html.writer, hooks, options);
    try testing.expectEqualStrings(expected_html, actual_html.written());
}

fn expectFailure(expected_message: []const u8, source: []const u8, options: Options) !void {
    try expectFailureWithHooks(expected_message, source, options, .{});
}

fn expectFailureWithHooks(expected_message: []const u8, source: []const u8, options: Options, hooks: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const markdown = try parse(allocator, &scanner);
    var actual_html: std.Io.Writer.Allocating = .init(allocator);
    try reporter.expectFailure(
        expected_message,
        markdown.render(&reporter, &actual_html.writer, hooks, options),
    );
}

test "render empty string" {
    try expect("", "", .{});
    try expect("", "", .{ .is_inline = true });
    try expect("", "", .{ .first_block_only = true });
    try expect("", "", .{ .is_inline = true, .first_block_only = true });
}

test "render text" {
    try expect("<p>Hello world!</p>", "Hello world!", .{});
    try expect("Hello world!", "Hello world!", .{ .is_inline = true });
    try expect("<p>Hello world!</p>", "Hello world!", .{ .first_block_only = true });
    try expect("Hello world!", "Hello world!", .{ .is_inline = true, .first_block_only = true });
}

test "render first block only" {
    const source =
        \\This is the first paragraph.
        \\
        \\This is the second paragraph.
    ;
    try expect("<p>This is the first paragraph.</p>", source, .{ .first_block_only = true });
    try expect("This is the first paragraph.", source, .{ .is_inline = true, .first_block_only = true });
}

test "render first block only with gap" {
    const source =
        \\
        \\This is the first paragraph.
        \\
        \\This is the second paragraph.
    ;
    try expect("<p>This is the first paragraph.</p>", source, .{ .first_block_only = true });
    try expect("This is the first paragraph.", source, .{ .is_inline = true, .first_block_only = true });
}

test "render backslash at end" {
    try expect("<p>\\</p>", "\\", .{});
    try expect("<p>Foo\\</p>", "Foo\\", .{});
}

test "render backslash before newline" {
    try expect("<p>\\</p>", "\\\n", .{});
}

test "render backslash scapes" {
    try expect(
        \\<p># _nice_ `stuff` \</p>
    ,
        \\\# \_nice\_ \`stuff\` \\
    , .{});
}

test "render inline raw html" {
    try expect("<p><cite>Foo</cite></p>", "<cite>Foo</cite>", .{});
}

test "render Markdown within raw inline html" {
    try expect("<p><cite><i>Foo</i></cite></p>", "<cite>_Foo_</cite>", .{});
}

test "render entities" {
    try expect("<p>1 + 1 &lt; 3, X>Y, AT&T</p>", "1 + 1 < 3, X>Y, AT&T", .{});
}

test "render raw entities" {
    try expect("<p>I want a &dollar;</p>", "I want a &dollar;", .{});
}

test "render inline element after false raw inline html" {
    try expect("<p>x&lt;y<i>z</i></p>", "x<y_z_", .{});
}

test "render inline element after false raw block html" {
    try expect("<p>&lt;div jk not a <i>div</i></p>", "<div jk not a _div_", .{});
}

test "render raw block html" {
    try expect(
        \\<div id="foo">
        \\Just in a div.
        \\</div>
    ,
        \\<div id="foo">
        \\Just in a div.
        \\</div>
    , .{});
}

test "render text around raw block html" {
    try expect(
        \\<p>Before</p>
        \\<block>
        \\After (part of block)
    ,
        \\Before
        \\<block>
        \\After (part of block)
    , .{});
}

test "render inlines around raw block html" {
    try expect(
        \\<p><i>Before</i></p>
        \\<block>
        \\<i>After (part of block)</i>
    ,
        \\_Before_
        \\<block>
        \\_After (part of block)_
    , .{});
}

test "render text after exiting raw block html" {
    try expect(
        \\<block>
        \\<p>After (not part of block)</p>
    ,
        \\<block>
        \\
        \\After (not part of block)
    , .{});
}

test "render text before and after exiting raw block html" {
    try expect(
        \\<block>
        \\After (part of block)
        \\<p>After (not part of block)</p>
    ,
        \\<block>
        \\After (part of block)
        \\
        \\After (not part of block)
    , .{});
}

test "render inlines before and after exiting raw block html" {
    try expect(
        \\<block>
        \\<i>After (part of block)</i>
        \\<p><i>After (not part of block)</i></p>
    ,
        \\<block>
        \\_After (part of block)_
        \\
        \\_After (not part of block)_
    , .{});
}

test "render raw block html with inline elements" {
    try expect(
        \\<div id="foo">
        \\Just in a <b>div</b>.
        \\</div>
    ,
        \\<div id="foo">
        \\Just in a **div**.
        \\</div>
    , .{});
}

test "render raw block html with nested paragraph" {
    try expect(
        \\<div>
        \\<p>Paragraph.</p>
        \\</div>
    ,
        \\<div>
        \\
        \\Paragraph.
        \\
        \\</div>
    , .{});
}

test "render raw block html with nested blockquote and list" {
    try expect(
        \\<div>
        \\<blockquote>
        \\<p>Paragraph.</p>
        \\<ul>
        \\<li>list</li>
        \\</ul>
        \\</blockquote>
        \\</div>
    ,
        \\<div>
        \\> Paragraph.
        \\>
        \\> - list
        \\</div>
    , .{});
}

test "render raw block html with nested thematic break" {
    try expect(
        \\<div>
        \\<hr>
        \\No paragraph!
        \\</div>
    ,
        \\<div>
        \\* * *
        \\No paragraph!
        \\</div>
    , .{});
}

test "render raw block html with nested thematic break and paragraph" {
    try expect(
        \\<div>
        \\<hr>
        \\<p>Yes paragraph!</p>
        \\</div>
    ,
        \\<div>
        \\* * *
        \\
        \\Yes paragraph!
        \\</div>
    , .{});
}

test "render code" {
    try expect("<p><code>foo_bar</code></p>", "`foo_bar`", .{});
}

test "render code with backslash" {
    try expect("<p><code>\\newline</code></p>", "`\\newline`", .{});
}

test "render code with entities" {
    try expect("<p><code>&lt;foo> &amp;amp;</code></p>", "`<foo> &amp;`", .{});
}

test "render emphasis" {
    try expect("<p>Hello <i>world</i>!</p>", "Hello _world_!", .{});
}

test "render strong" {
    try expect("<p>Hello <b>world</b>!</p>", "Hello **world**!", .{});
}

test "render nested inlines" {
    try expect(
        \\<p>a <b>b <i>c <code>d</code> e</i> f</b> g</p>
    ,
        \\a **b _c `d` e_ f** g
    , .{});
}

test "render inline link" {
    try expect("<p><a href=\"#bar\">foo</a></p>", "[foo](#bar)", .{});
}

test "render reference link" {
    try expect(
        \\<p>Look at <a href="https://example.com">foo</a>.</p>
    ,
        \\Look at [foo][bar].
        \\
        \\[bar]: https://example.com
    , .{});
}

test "render shortcut reference link" {
    try expect(
        \\<p>Look at <a href="https://example.com">foo</a>.</p>
    ,
        \\Look at [foo].
        \\
        \\[foo]: https://example.com
    , .{});
}

test "render link with escaped brackets" {
    try expect(
        \\<p><a href="1">]</a></p>
        \\<p><a href="2"><code>]</code></a></p>
        \\<p><a href="3"><code>\</code></a></p>
    ,
        \\[\]](1)
        \\
        \\[`]`](2)
        \\
        \\[`\`](3)
    , .{});
}

test "render heading" {
    try expect("<h1>This is h1</h1>", "# This is h1", .{});
}

test "render all headings" {
    try expect(
        \\<h1>This is h1</h1>
        \\<h2>This is h2</h2>
        \\<h3>This is h3</h3>
        \\<h4>This is h4</h4>
        \\<h5>This is h5</h5>
        \\<h6>This is h6</h6>
        \\<p>####### There is no h7</p>
    ,
        \\# This is h1
        \\## This is h2
        \\### This is h3
        \\#### This is h4
        \\##### This is h5
        \\###### This is h6
        \\####### There is no h7
    , .{});
}

test "render false heading without space" {
    try expect("<p>#1</p>", "#1", .{});
}

test "render heading with multiple spaces" {
    try expect("<h1>  X</h1>", "#   X", .{});
}

test "render inline after false heading" {
    try expect("<p>####### <i>hi</i></p>", "####### _hi_", .{});
}

test "render heading id" {
    try expect(
        \\<h1 id="this-is-h1">This is h1</h1>
        \\<h6 id="this-is-h6">This is h6</h6>
        \\<h2 id="abcxyz-abcxyz-0123456789">abcxyz ABCXYZ 0123456789</h2>
        \\<h2 id="cool-stuff"><b>Cool</b> <i>stuff</i></h2>
    ,
        \\# This is h1
        \\###### This is h6
        \\## abcxyz ABCXYZ 0123456789
        \\## **Cool** _stuff_
    , .{ .auto_heading_ids = true });
}

test "render shifted heading (positive)" {
    try expect("<h2>Foo</h2>", "# Foo", .{ .shift_heading_level = 1 });
    try expect("<h3>Foo</h3>", "## Foo", .{ .shift_heading_level = 1 });
    try expect("<h6>Foo</h6>", "###### Foo", .{ .shift_heading_level = 1 });
}

test "render shifted heading (negative)" {
    try expect("<h1>Foo</h1>", "# Foo", .{ .shift_heading_level = -1 });
    try expect("<h1>Foo</h1>", "## Foo", .{ .shift_heading_level = -1 });
    try expect("<h5>Foo</h5>", "###### Foo", .{ .shift_heading_level = -1 });
}

test "render false block inside heading" {
    try expect("<h1>> Not a blockquote</h1>", "# > Not a blockquote", .{});
}

test "render toc without heading ids" {
    try expect("", "<toc/>", .{ .auto_heading_ids = false });
}

test "render empty toc" {
    try expect(
        \\<nav class="toc">
        \\<h1>Contents</h1>
        \\<ul>
        \\</ul></nav>
    ,
        \\<toc/>
    , .{ .auto_heading_ids = true });
}

test "render toc with one heading before" {
    try expect(
        \\<h1 id="foo-bar">Foo <i>bar</i></h1>
        \\<nav class="toc">
        \\<h1>Contents</h1>
        \\<ul>
        \\</ul></nav>
    ,
        \\# Foo _bar_
        \\<toc/>
    , .{ .auto_heading_ids = true });
}

test "render toc with one heading after" {
    try expect(
        \\<nav class="toc">
        \\<h1>Contents</h1>
        \\<ul>
        \\<li><a href="#foo-bar">Foo <i>bar</i></a></li>
        \\</ul></nav>
        \\<h1 id="foo-bar">Foo <i>bar</i></h1>
    ,
        \\<toc/>
        \\# Foo _bar_
    , .{ .auto_heading_ids = true });
}

test "render toc with multiple headings" {
    try expect(
        \\<nav class="toc">
        \\<h1>Contents</h1>
        \\<ul>
        \\<li><a href="#a">a</a></li>
        \\<li><a href="#c">c</a></li>
        \\</ul></nav>
        \\<h1 id="a">a</h1>
        \\<h2 id="b">b</h2>
        \\<h1 id="c">c</h1>
    ,
        \\<toc/>
        \\# a
        \\## b
        \\# c
    , .{ .auto_heading_ids = true });
}

test "render unordered list" {
    try expect(
        \\<p>Here is the list:</p>
        \\<ul>
        \\<li>Apples</li>
        \\<li>Oranges</li>
        \\</ul>
    ,
        \\Here is the list:
        \\
        \\- Apples
        \\- Oranges
    , .{});
}

test "render ordered list" {
    try expect(
        \\<p>Here is the list:</p>
        \\<ol>
        \\<li>Apples</li>
        \\<li>Oranges</li>
        \\</ol>
    ,
        \\Here is the list:
        \\
        \\1. Apples
        \\9. Oranges
    , .{});
}

test "render multiple lists" {
    try expect(
        \\<ol>
        \\<li>Apples</li>
        \\<li>Oranges</li>
        \\</ol>
        \\<ul>
        \\<li>other <b>stuff</b></li>
        \\<li>blah blah</li>
        \\</ul>
    ,
        \\1. Apples
        \\9. Oranges
        \\
        \\- other **stuff**
        \\- blah blah
    , .{});
}

test "render lists with blank lines" {
    try expect(
        \\<ul>
        \\<li>one</li>
        \\<li>two</li>
        \\</ul>
    ,
        \\- one
        \\
        \\- two
    , .{});
}

test "render two thematic breaks" {
    try expect("<hr>\n<hr>", "* * *\n* * *", .{});
}

test "render three asterisks with text after" {
    try expect("<p>* * *foo</p>", "* * *foo", .{});
}

test "render two thematic breaks in blockquote" {
    try expect(
        \\<blockquote>
        \\<hr>
        \\<hr>
        \\</blockquote>
    ,
        \\> * * *
        \\> * * *
    , .{});
}

test "render blockquote with blank final line" {
    try expect(
        \\<blockquote>
        \\<p>Hi</p>
        \\</blockquote>
    ,
        \\> Hi
        \\>
    , .{});
}

test "render a few things" {
    try expect(
        \\<h1>Hello <b>world</b>!</h1>
        \\<p>Here is <i>some</i> text.</p>
        \\<hr>
        \\<p>And some more.</p>
    ,
        \\# Hello **world**!
        \\
        \\Here is _some_ text.
        \\
        \\* * *
        \\
        \\And some more.
    , .{});
}

test "render nested blockquotes" {
    try expect(
        \\<p>Quote:</p>
        \\<blockquote>
        \\<p>Some stuff.</p>
        \\<ul>
        \\<li>For example.</li>
        \\</ul>
        \\<blockquote>
        \\<blockquote>
        \\<p>Deep!</p>
        \\</blockquote>
        \\<p>End</p>
        \\</blockquote>
        \\</blockquote>
    ,
        \\Quote:
        \\
        \\> Some stuff.
        \\>
        \\> - For example.
        \\>
        \\> > > Deep!
        \\> >
        \\> > End
    , .{});
}

test "render adjacent blockquotes" {
    try expect(
        \\<blockquote>
        \\<p>First quote</p>
        \\</blockquote>
        \\<blockquote>
        \\<p>Second quote</p>
        \\</blockquote>
    ,
        \\> First quote
        \\
        \\> Second quote
    , .{});
}

test "render code block" {
    try expect("<pre>\n<code>Foo</code>\n</pre>", "```\nFoo\n```", .{});
}

test "render code block with language but no highlighting" {
    try expect("<pre>\n<code>Foo</code>\n</pre>", "```html\nFoo\n```", .{});
}

test "render code block with blank lines" {
    try expect("<pre>\n<code>\n\n</code>\n</pre>", "```\n\n\n\n```", .{});
}

test "render code block with special characters" {
    try expect(
        \\<pre>
        \\<code>&lt;foo> [bar] `baz` _qux_ &amp; \</code>
        \\</pre>
    ,
        \\```
        \\<foo> [bar] `baz` _qux_ & \
        \\```
    , .{});
}

test "render code block with triple backticks inside" {
    try expect(
        \\<pre>
        \\<code>```not the end</code>
        \\</pre>
    ,
        \\```
        \\```not the end
        \\```
    , .{});
}

test "render block element after code block" {
    try expect(
        \\<pre>
        \\<code>Some code</code>
        \\</pre>
        \\<h1>Heading</h1>
    ,
        \\```
        \\Some code
        \\```
        \\# Heading
    , .{});
}

test "render code block in blockquote" {
    try expect(
        \\<blockquote>
        \\<pre>
        \\<code>Some code
        \\
        \\> > ></code>
        \\</pre>
        \\</blockquote>
    ,
        \\> ```
        \\> Some code
        \\>
        \\> > > >
        \\> ```
    , .{});
}

test "unclosed code block" {
    try expectFailure("<input>:1:4: missing closing ```", "```", .{});
}

test "unclosed code block in blockquote" {
    try expectFailure("<input>:1:6: missing closing ```", "> ```", .{});
}

test "unclosed code block in blockquote with newline" {
    try expectFailure("<input>:1:6: missing closing ```", "> ```\n", .{});
}

test "unclosed code block in blockquote with text after" {
    try expectFailure("<input>:2:1: missing closing ```", "> ```\n\nFoo", .{});
}

test "render smart typography" {
    try expect(
        \\<p>This – “that isn’t 1–2” … other.</p>
    ,
        \\This -- "that isn't 1--2" ... other.
    , .{});
}

test "render space-aware smart typography when space is already consumed" {
    try expect("<h1>– en dash not em</h1>", "# -- en dash not em", .{});
}

test "render footnotes" {
    try expect(
        \\<p>Foo<sup id="fnref:1" class="fnref"><a href="#fn:1">1</a></sup>.</p>
        \\<p>Bar<sup id="fnref:2" class="fnref"><a href="#fn:2">2</a></sup>.</p>
        \\<hr class="footnotes-rule">
        \\<ol class="footnotes">
        \\<li id="fn:1"><i>first</i>&nbsp;<a href="#fnref:1">↩︎</a></li>
        \\<li id="fn:2">second&nbsp;<a href="#fnref:2">↩︎</a></li>
        \\</ol>
    ,
        \\Foo[^1].
        \\
        \\Bar[^2].
        \\
        \\[^1]: _first_
        \\[^2]: second
    , .{});
}

test "render footnotes with blank line" {
    try expect(
        \\<p>Foo<sup id="fnref:1" class="fnref"><a href="#fn:1">1</a></sup>.</p>
        \\<p>Bar<sup id="fnref:2" class="fnref"><a href="#fn:2">2</a></sup>.</p>
        \\<hr class="footnotes-rule">
        \\<ol class="footnotes">
        \\<li id="fn:1"><i>first</i>&nbsp;<a href="#fnref:1">↩︎</a></li>
        \\<li id="fn:2">second&nbsp;<a href="#fnref:2">↩︎</a></li>
        \\</ol>
    ,
        \\Foo[^1].
        \\
        \\Bar[^2].
        \\
        \\[^1]: _first_
        \\
        \\[^2]: second
    , .{});
}

test "no footnotes if first block only" {
    try expect(
        \\<p>Foo.</p>
    ,
        \\Foo[^1].
        \\[^1]: second
    , .{ .first_block_only = true });
}

test "out_has_footnotes false" {
    var has_footnotes = false;
    try expect("<p>Foo</p>", "Foo", .{ .out_has_footnotes = &has_footnotes });
    try testing.expectEqual(false, has_footnotes);
}

test "out_has_footnotes true" {
    var has_footnotes = false;
    try expect(
        \\<p>Foo<sup id="fnref:1" class="fnref"><a href="#fn:1">1</a></sup></p>
    , "Foo[^1]", .{ .out_has_footnotes = &has_footnotes });
    try testing.expectEqual(true, has_footnotes);
}

test "render figure (url)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\<figcaption>Some caption</figcaption>
        \\</figure>
    ,
        \\![Some caption](rabbit.jpg)
    , .{});
}

test "render figure (reference)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\<figcaption>Some caption</figcaption>
        \\</figure>
    ,
        \\![Some caption][img]
        \\
        \\[img]: rabbit.jpg
    , .{});
}

test "render figure (shortcut)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\<figcaption>Some caption</figcaption>
        \\</figure>
    ,
        \\![Some caption]
        \\
        \\[Some caption]: rabbit.jpg
    , .{});
}

test "render figure without caption (url)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![](rabbit.jpg)
    , .{});
}

test "render figure without caption (reference)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![][img]
        \\
        \\[img]: rabbit.jpg
    , .{});
}

test "render figure with size (url)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg" width="20" height="30.5">
        \\</figure>
    ,
        \\![](rabbit.jpg "20x30.5")
    , .{});
}

test "render figure with size (reference)" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg" width="20" height="30.5">
        \\</figure>
    ,
        \\![][img]
        \\
        \\[img]: rabbit.jpg "20x30.5"
    , .{});
}

test "render figure with size and class (url)" {
    try expect(
        \\<figure class="foo">
        \\<img src="rabbit.jpg" width="1" height="1">
        \\</figure>
    ,
        \\![](rabbit.jpg "1x1 .foo")
    , .{});
}

test "render figure with size and class (reference)" {
    try expect(
        \\<figure class="foo">
        \\<img src="rabbit.jpg" width="1" height="1">
        \\</figure>
    ,
        \\![][img]
        \\
        \\[img]: rabbit.jpg "1x1 .foo"
    , .{});
}

test "render figure with lazy image" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg" width="20" height="30.5" loading="lazy">
        \\</figure>
    ,
        \\![](rabbit.jpg "20x30.5 lazy")
    , .{});
}

test "render figure with link in caption" {
    try expect(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\<figcaption>Some <a href="foo">caption</a> here</figcaption>
        \\</figure>
    ,
        \\![Some [caption] here](rabbit.jpg)
        \\[caption]: foo
    , .{});
}

test "render top-caption figure (url)" {
    try expect(
        \\<figure>
        \\<figcaption>Some caption</figcaption>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![^Some caption](rabbit.jpg)
    , .{});
}

test "render top-caption figure (reference)" {
    try expect(
        \\<figure>
        \\<figcaption>Some caption</figcaption>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![^Some caption][img]
        \\
        \\[img]: rabbit.jpg
    , .{});
}

test "render top-caption figure (attempting shortcut)" {
    try expect(
        \\<figure>
        \\<figcaption>Some caption</figcaption>
        \\<img src="">
        \\</figure>
    ,
        \\![^Some caption]
    , .{});
}

test "render top-caption figure with link in caption" {
    try expect(
        \\<figure>
        \\<figcaption>Some <a href="foo">caption</a> here</figcaption>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![^Some [caption] here](rabbit.jpg)
        \\[caption]: foo
    , .{});
}

test "render image inline" {
    try expect("<p>Some picture: <img src=\"x\"></p>", "Some picture: ![](x)", .{});
}

test "render unbalanced right bracket" {
    try expect(
        \\<p>Some ] out of nowhere</p>
    ,
        \\Some ] out of nowhere
    , .{});
}

test "render empty table" {
    const html =
        \\<table>
        \\<tr><th></th></tr>
        \\</table>
    ;
    try expect(html, "|", .{});
    try expect(html, "||", .{});
    try expect(html, "| |", .{});
    try expect(html, "|  |", .{});
}

test "render basic table" {
    try expect(
        \\<table>
        \\<tr><th>Fruit</th><th>Color</th></tr>
        \\<tr><td>Apple</td><td>Red</td></tr>
        \\<tr><td>Banana</td><td>Yellow</td></tr>
        \\</table>
    ,
        \\| Fruit | Color |
        \\| Apple | Red |
        \\| Banana | Yellow |
    , .{});
}

test "render table with heading separator" {
    try expect(
        \\<table>
        \\<tr><th>Fruit</th><th>Color</th></tr>
        \\<tr><td>Apple</td><td>Red</td></tr>
        \\<tr><td>Banana</td><td>Yellow</td></tr>
        \\</table>
    ,
        \\| Fruit | Color |
        \\| ----- | ----- |
        \\| Apple | Red |
        \\| Banana | Yellow |
    , .{});
}

test "render table with weird spacing" {
    try expect(
        \\<table>
        \\<tr><th>a</th><th>b</th></tr>
        \\<tr><td>c</td><td>d</td></tr>
        \\<tr><td>e</td><td>f</td></tr>
        \\<tr><td>g</td><td>h</td></tr>
        \\</table>
    ,
        \\|a|b|
        \\|-|-|
        \\|  c  |  d  |
        \\|e |f |
        \\| g| h|
    , .{});
}

test "render table omitting pipes at end" {
    try expect(
        \\<table>
        \\<tr><th>x</th><th>y</th></tr>
        \\<tr><td>z</td><td>w</td></tr>
        \\</table>
    ,
        \\| x | y
        \\| z | w
    , .{});
}

test "render table with inlines in cells" {
    try expect(
        \\<table>
        \\<tr><th><i>x</i></th><th><code>this || that</code></th><th><a href="b">a</a></th></tr>
        \\</table>
    ,
        \\| _x_ | `this || that` | [a](b) |
    , .{});
}

test "inline math" {
    try expect("<p><math><mi>x</mi></math></p>", "$x$", .{});
}

test "display math" {
    try expect("<div class=\"math-block\"><math display=\"block\"><mi>x</mi></math></div>", "$$x$$", .{});
}

test "inline math with newlines" {
    try expect("<p><math><mi>x</mi>\n<mi>y</mi></math></p>", "$x\ny$", .{});
}

test "display math with newlines" {
    try expect("<div class=\"math-block\"><math display=\"block\"><mi>x</mi>\n<mi>y</mi></math></div>", "$$x\ny$$", .{});
}

test "inline math mixed with other stuff" {
    try expect("<p>Foo <math><mi>x</mi></math> bar $ <math><mi>y</mi></math></p>", "Foo $x$ bar \\$ $y$", .{});
}

test "punctuation tucked into math" {
    try expect("<p><math><mi>x</mi><mtext>.</mtext></math></p>", "$x$.", .{});
}

test "unclosed inline math" {
    try expectFailure("<input>:1:2: missing closing $", "$", .{});
}

test "unclosed block math" {
    try expectFailure("<input>:1:3: missing closing $$", "$$", .{});
}

test "unclosed inline at end" {
    try expectFailure(
        \\<input>:1:5: unclosed <i> tag
    ,
        \\_foo
    , .{});
}

test "unclosed inline in middle" {
    try expectFailure(
        \\<input>:1:15: unclosed <b> tag
    ,
        \\> Some **stuff
        \\
        \\And more.
    , .{});
}

test "unclosed inline code" {
    try expectFailure(
        \\<input>:1:6: unclosed <code> tag
    ,
        \\`nice
        \\foo`
    , .{});
}

test "exceed max inline tag depth" {
    try expectFailure(
        \\<input>:1:21: exceeded maximum tag depth (8)
    ,
        \\_ ** _ ** _ ** _ ** `
    , .{});
}

test "exceed max inline tag depth with link" {
    try expectFailure(
        \\<input>:1:21: exceeded maximum tag depth (8)
    ,
        \\_ ** _ ** _ ** _ ** [foo](bar)
    , .{});
}

test "exceed max block tag depth" {
    try expectFailure(
        \\<input>:1:17: exceeded maximum tag depth (8)
    ,
        \\> > > > > > > > -
    , .{});
}

test "writeUrl hook" {
    const hooks = struct {
        data: []const u8 = "data",
        fn writeUrl(self: @This(), writer: *std.Io.Writer, context: HookContext, url: []const u8) !void {
            try writer.print("hook got {s} in {s}, can access {s}", .{ url, context.filename, self.data });
        }
    }{};
    try expectWithHooks(
        \\<p><a href="hook got #foo in <input>, can access data">text</a></p>
    ,
        \\[text](#foo)
    , .{}, hooks);
}

test "failure in writeUrl hook (inline)" {
    const hooks = struct {
        fn writeUrl(self: @This(), writer: *std.Io.Writer, context: HookContext, url: []const u8) !void {
            _ = writer;
            _ = self;
            return context.fail("{s}: bad url", .{url});
        }
    }{};
    try expectFailureWithHooks(
        \\<input>:1:18: xyz: bad url
    ,
        \\[some link text](xyz)
    , .{}, hooks);
}

test "failure in writeUrl hook (reference)" {
    const hooks = struct {
        fn writeUrl(self: @This(), writer: *std.Io.Writer, context: HookContext, url: []const u8) !void {
            _ = writer;
            _ = self;
            return context.fail("{s}: bad url", .{url});
        }
    }{};
    try expectFailureWithHooks(
        \\<input>:3:8: xyz: bad url
    ,
        \\[some
        \\link text][ref]
        \\[ref]: xyz
    , .{}, hooks);
}

test "failure with default renderTemplate hook" {
    try expectFailure(
        \\<input>:1:1: no hook installed for renderTemplate
    ,
        \\<template src="foo"/>
    , .{});
}

test "failure with default parseAndRenderTemplate hook" {
    try expectFailure(
        \\<input>:1:1: no hook installed for parseAndRenderTemplate
    ,
        \\<template>
        \\</template>
    , .{});
}

test "unclosed block template" {
    try expectFailure(
        \\<input>:1:11: encountered EOF while looking for "</template>"
    ,
        \\<template>
    , .{});
}

test "unclosed inline template" {
    try expectFailure(
        \\<input>:1:13: encountered EOF while looking for "</template>"
    ,
        \\- <template>
    , .{});
}

test "block template close tag not on its own line (before)" {
    try expectFailure(
        \\<input>:2:2: expected "</template>" to be on its own line
    ,
        \\<template>
        \\x</template>
    , .{});
}

test "block template close tag not on its own line (after)" {
    try expectFailure(
        \\<input>:2:1: expected "</template>" to be on its own line
    ,
        \\<template>
        \\</template>x
    , .{});
}

test "renderTemplate hook" {
    const hooks = struct {
        fn renderTemplate(self: @This(), writer: *std.Io.Writer, context: HookContext, name: []const u8) !void {
            _ = self;
            try writer.print("render template {s} in {s}", .{ name, context.filename });
        }
    }{};
    try expectWithHooks(
        \\render template block in <input>
        \\<p>Hi. render template inline in <input>.</p>
    ,
        \\<template src="block"/>
        \\Hi. <template src="inline"/>.
    , .{}, hooks);
}

test "parseAndRenderTemplate hook" {
    const hooks = struct {
        fn parseAndRenderTemplate(self: @This(), writer: *std.Io.Writer, context: HookContext, scanner: *Scanner) !void {
            _ = self;
            try writer.print("parse and render template '{s}' in {s}", .{ scanner.consumeRest(), context.filename });
        }
    }{};
    try expectWithHooks(
        \\parse and render template 'BLOCK
        \\' in <input>
        \\<p>Hi. parse and render template 'INLINE' in <input>.</p>
    ,
        \\<template>
        \\BLOCK
        \\</template>
        \\Hi. <template>INLINE</template>.
    , .{}, hooks);
}

test "two block templates in a row" {
    const hooks = struct {
        fn renderTemplate(self: @This(), writer: *std.Io.Writer, context: HookContext, name: []const u8) !void {
            _ = self;
            try writer.print("render template {s} in {s}", .{ name, context.filename });
        }
    }{};
    try expectWithHooks(
        \\render template 1 in <input>
        \\render template 2 in <input>
    ,
        \\<template src="1"/>
        \\<template src="2"/>
    , .{}, hooks);
}
