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
//! heading IDs, footnotes, code highlighting, (TODO!) tables, and (TODO!) TeX
//! math in dollar signs rendered to MathML.
//!
//! It is customizable with Options and with Hooks. The options are mostly
//! flags, e.g. whether to enable code highlighting. The hooks allow you to
//! rewrite URLs in links and to override how images are rendered.

const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Highlighter = @import("Highlighter.zig");
const Language = Highlighter.Language;
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
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
    var end: usize = undefined;
    scanner.offset = scanner.source.len;
    while (true) {
        while (scanner.offset > start and scanner.prev(0) == '\n') scanner.uneat();
        end = scanner.offset;
        while (scanner.offset > start and scanner.prev(0) != '\n') scanner.uneat();
        const start_of_line = scanner.offset;
        if (!scanner.consume('[')) break;
        if (scanner.consume('^')) break;
        const label = scanner.consumeLineUntil(']') orelse break;
        if (!scanner.consumeString(": ")) break;
        try links.put(allocator, label, scanner.source[scanner.offset..end]);
        scanner.offset = start_of_line;
    }
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
    // End of file
    eof,

    // Blocks tokens
    @"\n",
    @"#": u8,
    @"-",
    @"1.",
    @">",
    @"* * *\n",
    @"```x\n": []const u8,
    stay_in_code_block,
    @"```\n",
    // @"$$",
    @"![...](x)": []const u8,
    @"![...][x]": []const u8,
    @"![^",
    @"[^x]: ": []const u8,
    @"| ",

    // Inline tokens
    text: []const u8,
    @"<",
    @"&",
    @"\\x": u8,
    // @"$",
    @"[^x]": []const u8,
    _,
    @"**",
    @"`",
    @"[...](x)": []const u8,
    @"[...][x]": []const u8,
    @" | ",
    lsquo,
    rsquo,
    ldquo,
    rdquo,
    @"--",
    @" -- ",
    @"...",

    // Neither block nor inline
    @"]",
    @"](x)": []const u8,
    @"][x]": []const u8,

    fn linkish(url_or_label: []const u8, args: struct { label: bool, figure: bool }) Token {
        return switch (args.figure) {
            false => if (args.label) .{ .@"[...][x]" = url_or_label } else .{ .@"[...](x)" = url_or_label },
            true => if (args.label) .{ .@"![...][x]" = url_or_label } else .{ .@"![...](x)" = url_or_label },
        };
    }

    fn isInline(self: Token) bool {
        return @intFromEnum(self) >= @intFromEnum(Token.text);
    }
};

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

    fn fail(self: Tokenizer, comptime format: []const u8, args: anytype) Reporter.Error {
        return self.scanner.failAtOffset(self.token_start, format, args);
    }

    fn remaining(self: Tokenizer) []const u8 {
        assert(self.peeked == null);
        return self.scanner.source[self.scanner.offset..];
    }

    fn next(self: *Tokenizer, in_code_block: bool) Token {
        if (in_code_block) {
            assert(self.peeked == null);
            self.token_start = self.scanner.offset;
            if (self.scanner.eof()) return .eof;
            if (self.scanner.consumeStringEol("```")) return .@"```\n";
            return .stay_in_code_block;
        }
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
            '<' => if (scanner.next()) |char| switch (char) {
                '/', 'a'...'z' => if (scanner.consumeLineUntil('>') != null and scanner.peekEol()) {
                    self.in_raw_html_block = true;
                    // We can't just return null here (as we do for raw inline HTML)
                    // because `in_raw_html_block` needs to apply to this token.
                    return .{ .text = scanner.source[self.token_start..scanner.offset] };
                },
                else => {},
            },
            '>' => if (scanner.consume(' ') or scanner.peekEol()) {
                self.block_allowed = true;
                return .@">";
            },
            '`' => if (scanner.consumeString("``")) {
                self.block_allowed = true;
                return .{ .@"```x\n" = scanner.consumeUntilEol() };
            },
            '$' => if (scanner.consume('$')) {
                // This is temporary, to avoid interpreting math as Markdown.
                while (scanner.next()) |c| if (c == '$') break;
                scanner.expect('$') catch unreachable;
                return .{ .text = scanner.source[self.token_start..scanner.offset] };
            },
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
            '!' => if (scanner.consume('['))
                if (self.recognizeAfterOpenBracket(.figure)) |token| return token,
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
                if (scanner.peek()) |char| switch (char) {
                    '/', 'a'...'z' => if (scanner.consumeLineUntil('>')) |_| return null,
                    else => {},
                };
                return .@"<";
            },
            '\\' => if (scanner.next()) |char| return .{ .@"\\x" = char },
            '$' => {
                // This is temporary, to avoid interpreting math as Markdown.
                while (scanner.next()) |c| if (c == '$') break;
                return .{ .text = scanner.source[self.token_start..scanner.offset] };
            },
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
                return if (prev == null or prev == ' ' or prev == '\n') .lsquo else .rsquo;
            },
            '"' => {
                const prev = scanner.prev(1);
                return if (prev == null or prev == ' ' or prev == '\n') .ldquo else .rdquo;
            },
            '-' => if (scanner.consume('-')) return .@"--",
            ' ' => {
                scanner.skipMany(' ');
                if (scanner.consumeString("-- ")) return .@" -- ";
                if (scanner.consume('|')) return self.recognizeAfterPipe();
            },
            '|' => return self.recognizeAfterPipe(),
            '.' => if (scanner.consumeString("..")) return .@"...",
            else => {},
        }
        return null;
    }

    fn recognizeAfterNewline(self: *Tokenizer) Token {
        if (self.scanner.consumeMany('\n') > 0) self.in_raw_html_block = false;
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
        defer scanner.offset = start_bracketed;
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
        const is_figure = kind == .figure;
        const closing_char: u8 = blk: {
            const end_bracketed = scanner.offset - 1;
            if (scanner.next()) |char| switch (char) {
                '(' => break :blk ')',
                '[' => break :blk ']',
                else => {},
            };
            // Shortcut reference link.
            const label = scanner.source[start_bracketed..end_bracketed];
            self.link_depth += 1;
            return Token.linkish(label, .{ .label = true, .figure = is_figure });
        };
        const url_or_label = scanner.consumeLineUntil(closing_char) orelse return null;
        const is_label = closing_char == ']';
        self.link_depth += 1;
        return Token.linkish(url_or_label, .{ .label = is_label, .figure = is_figure });
    }
};

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Tag = std.meta.Tag(Token);
    var expected_tags = std.ArrayList(Tag).init(allocator);
    for (expected) |token| try expected_tags.append(token);
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = try Tokenizer.init(&scanner);
    var actual = std.ArrayList(Token).init(allocator);
    var actual_tags = std.ArrayList(Tag).init(allocator);
    while (true) {
        const token = tokenizer.next(false);
        try actual.append(token);
        try actual_tags.append(token);
        if (token == .eof) break;
    }
    try testing.expectEqualSlices(Tag, expected_tags.items, actual_tags.items);
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
        .eof,
    },
        \\![Foo](bar)
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

pub const Options = struct {
    is_inline: bool = false,
    first_block_only: bool = false,
    highlight_code: bool = false,
    auto_heading_ids: bool = false,
    shift_heading_level: i8 = 0,
};

fn WithDefaultHooks(comptime Inner: type) type {
    return struct {
        const Self = @This();
        const Underlying = switch (@typeInfo(Inner)) {
            .Pointer => |info| info.child,
            else => Inner,
        };
        inner: Inner,

        fn writeUrl(self: Self, writer: anytype, context: HookContext, url: []const u8) !void {
            if (@hasDecl(Underlying, "writeUrl")) return self.inner.writeUrl(writer, context, url);
            try writer.writeAll(url);
        }

        fn writeImage(self: Self, writer: anytype, context: HookContext, url: []const u8) !void {
            if (@hasDecl(Underlying, "writeImage")) return self.inner.writeImage(writer, context, url);
            try fmt.format(writer, "<img src=\"{s}\">", .{url});
        }
    };
}

pub const HookContext = struct {
    reporter: *Reporter,
    source: []const u8,
    filename: []const u8,
    ptr: [*]const u8 = undefined,

    fn at(self: HookContext, ptr: [*]const u8) HookContext {
        return HookContext{ .reporter = self.reporter, .source = self.source, .filename = self.filename, .ptr = ptr };
    }

    pub fn fail(self: HookContext, comptime format: []const u8, args: anytype) Reporter.Error {
        return self.reporter.failAt(self.filename, Location.fromPtr(self.source, self.ptr), format, args);
    }
};

pub fn render(
    self: Markdown,
    reporter: *Reporter,
    writer: anytype,
    hooks: anytype,
    options: Options,
) !void {
    // TODO(https://github.com/ziglang/zig/issues/1738): @intFromPtr should be unnecessary.
    const offset = @intFromPtr(self.text.ptr) - @intFromPtr(self.context.source.ptr);
    var scanner = Scanner{
        .source = self.context.source[0 .. offset + self.text.len],
        .reporter = reporter,
        .filename = self.context.filename,
        .offset = offset,
    };
    var tokenizer = try Tokenizer.init(&scanner);
    const full_hooks = WithDefaultHooks(@TypeOf(hooks)){ .inner = hooks };
    const hook_ctx = HookContext{ .reporter = reporter, .source = self.context.source, .filename = self.context.filename };
    return renderImpl(&tokenizer, writer, full_hooks, hook_ctx, self.context.links, options) catch |err| switch (err) {
        error.ExceededMaxTagDepth => return tokenizer.fail("exceeded maximum tag depth ({})", .{max_tag_depth}),
        else => return err,
    };
}

const max_tag_depth = 8;

fn Stack(comptime Tag: type) type {
    return struct {
        const Self = @This();
        items: std.BoundedArray(Tag, max_tag_depth) = .{},

        fn len(self: Self) usize {
            return self.items.len;
        }

        fn get(self: Self, i: usize) Tag {
            return self.items.get(i);
        }

        fn top(self: Self) ?Tag {
            return if (self.len() == 0) null else self.items.get(self.len() - 1);
        }

        fn push(self: *Self, writer: anytype, item: Tag) !void {
            try item.writeOpenTag(writer);
            try self.pushWithoutWriting(item);
        }

        fn pushWithoutWriting(self: *Self, item: Tag) !void {
            self.items.append(item) catch |err| return switch (err) {
                error.Overflow => error.ExceededMaxTagDepth,
            };
        }

        fn append(self: *Self, writer: anytype, items: anytype) !void {
            inline for (items) |item| try self.push(writer, item);
        }

        fn pop(self: *Self, writer: anytype) !void {
            try self.items.pop().writeCloseTag(writer);
        }

        fn popTag(self: *Self, writer: anytype, tag: std.meta.Tag(Tag)) !void {
            assert(self.top().? == tag);
            try self.pop(writer);
        }

        fn toggle(self: *Self, writer: anytype, item: Tag) !void {
            try if (self.top() == item) self.pop(writer) else self.push(writer, item);
        }

        fn truncate(self: *Self, writer: anytype, new_len: usize) !void {
            while (self.items.len > new_len) try self.pop(writer);
        }
    };
}

const BlockTag = union(enum) {
    p,
    li,
    // I'm making this fit in 8 bytes just because I can.
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
    footnote_ol,
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

    fn implicitChild(parent: ?BlockTag, footnote_label: ?[]const u8) ?BlockTag {
        return switch (parent orelse return .p) {
            .ul, .ol => .li,
            .blockquote => .p,
            .table, .tr => unreachable,
            .footnote_ol => .{ .footnote_li = footnote_label.? },
            else => null,
            // TODO exhaustive, and unreachable for p, li
        };
    }

    fn goesOnItsOwnLine(self: BlockTag) bool {
        return switch (self) {
            .p, .li, .h, .figcaption, .tr, .th, .td, .footnote_li => false,
            .ul, .ol, .blockquote, .figure, .table, .footnote_ol => true,
        };
    }

    fn writeOpenTag(self: BlockTag, writer: anytype) !void {
        switch (self) {
            .h => |h| if (h.source) |source_ptr| {
                try fmt.format(writer, "<h{} id=\"", .{h.level});
                try generateAutoIdUntilNewline(writer, source_ptr[0..h.source_len]);
                try writer.writeAll("\">");
            } else {
                try fmt.format(writer, "<h{}>", .{h.level});
            },
            .footnote_ol => try writer.writeAll("<hr>\n<ol class=\"footnotes\">"),
            .footnote_li => |label| try fmt.format(writer, "<li id=\"fn:{s}\">", .{label}),
            else => try fmt.format(writer, "<{s}>", .{@tagName(self)}),
        }
        if (self.goesOnItsOwnLine()) try writer.writeByte('\n');
    }

    fn writeCloseTag(self: BlockTag, writer: anytype) !void {
        if (self.goesOnItsOwnLine()) try writer.writeByte('\n');
        switch (self) {
            .h => |h| try fmt.format(writer, "</h{}>", .{h.level}),
            .footnote_ol => try writer.writeAll("</ol>"),
            .footnote_li => |label| try fmt.format(writer, "&nbsp;<a href=\"#fnref:{s}\">↩︎</a></li>", .{label}),
            else => try fmt.format(writer, "</{s}>", .{@tagName(self)}),
        }
    }
};

const InlineTag = enum {
    em,
    strong,
    code,
    a,

    fn writeOpenTag(self: InlineTag, writer: anytype) !void {
        try fmt.format(writer, "<{s}>", .{@tagName(self)});
    }

    fn writeCloseTag(self: InlineTag, writer: anytype) !void {
        try fmt.format(writer, "</{s}>", .{@tagName(self)});
    }
};

fn generateAutoIdUntilNewline(writer: anytype, source: []const u8) !void {
    var pending: enum { start, none, hyphen } = .start;
    for (source) |char| switch (char) {
        '\n' => break,
        'A'...'Z', 'a'...'z', '0'...'9' => {
            if (pending == .hyphen) try writer.writeByte('-');
            pending = .none;
            try writer.writeByte(std.ascii.toLower(char));
        },
        else => if (pending == .none) {
            pending = .hyphen;
        },
    };
}

fn maybeLookupUrl(scanner: *Scanner, links: LinkMap, url_or_label: []const u8, tag: std.meta.Tag(Token)) ![]const u8 {
    return switch (tag) {
        .@"[...](x)", .@"![...](x)", .@"](x)" => url_or_label,
        .@"[...][x]", .@"![...][x]", .@"][x]" => links.get(url_or_label) orelse
            scanner.failAtPtr(url_or_label.ptr, "link label '{s}' is not defined", .{url_or_label}),
        else => unreachable,
    };
}

fn renderImpl(tokenizer: *Tokenizer, writer: anytype, hooks: anytype, hook_ctx: HookContext, links: LinkMap, options: Options) !void {
    var blocks = Stack(BlockTag){};
    var inlines = Stack(InlineTag){};
    var highlighter = Highlighter{};
    var footnote_label: ?[]const u8 = null;
    var first_iteration = true;
    while (true) {
        var num_blocks_open: usize = 0;
        var all_open = num_blocks_open == blocks.len();
        var token = tokenizer.next(all_open and highlighter.active);
        while (!all_open) {
            switch (blocks.get(num_blocks_open)) {
                .p, .li, .h, .figure, .figcaption, .tr, .th, .td, .footnote_li => break,
                .ul => if (token != .@"-") break,
                .ol => if (token != .@"1.") break,
                .blockquote => if (token != .@">") break,
                .table => if (token != .@"| ") break,
                .footnote_ol => switch (token) {
                    .@"[^x]: " => |label| footnote_label = label,
                    else => break,
                },
            }
            num_blocks_open += 1;
            all_open = num_blocks_open == blocks.len();
            token = tokenizer.next(all_open and highlighter.active);
        }
        if (token == .eof) break;
        if (highlighter.active) {
            if (!all_open) return tokenizer.fail("missing closing ```", .{});
            switch (token) {
                .stay_in_code_block => try highlighter.line(writer, tokenizer.scanner),
                .@"```\n" => try highlighter.end(writer),
                else => unreachable,
            }
            continue;
        }
        try blocks.truncate(writer, num_blocks_open);
        if (token == .@"\n") continue;
        if (!first_iteration) try writer.writeByte('\n');
        if (blocks.top()) |block| if (block == .table) try blocks.append(writer, .{ .tr, .td });
        first_iteration = false;
        var need_implicit_block = !options.is_inline;
        while (true) {
            if (need_implicit_block and token.isInline()) {
                if (!(tokenizer.in_raw_html_block and blocks.len() == 0))
                    if (BlockTag.implicitChild(blocks.top(), footnote_label)) |block|
                        try blocks.push(writer, block);
                need_implicit_block = false;
            }
            switch (token) {
                .eof, .@"\n" => break,
                .@"* * *\n" => break try writer.writeAll("<hr>"),
                .@"```x\n" => |language_str| {
                    const language = if (options.highlight_code) Language.from(language_str) else null;
                    break try highlighter.begin(writer, language);
                },
                .stay_in_code_block, .@"```\n" => unreachable,
                .@"#" => |level| try blocks.push(writer, BlockTag.heading(tokenizer.remaining(), level, options)),
                .@"-" => try blocks.push(writer, .ul),
                .@"1." => try blocks.push(writer, .ol),
                .@">" => try blocks.push(writer, .blockquote),
                inline .@"![...](x)", .@"![...][x]" => |url_or_label, tag| {
                    const url = try maybeLookupUrl(tokenizer.scanner, links, url_or_label, tag);
                    try blocks.push(writer, .figure);
                    try hooks.writeImage(writer, hook_ctx.at(url.ptr), url);
                    try writer.writeByte('\n');
                    try blocks.push(writer, .figcaption);
                },
                .@"![^" => try blocks.append(writer, .{ .figure, .figcaption }),
                inline .@"](x)", .@"][x]" => |url_or_label, tag| {
                    const url = try maybeLookupUrl(tokenizer.scanner, links, url_or_label, tag);
                    try blocks.popTag(writer, .figcaption);
                    try writer.writeByte('\n');
                    try hooks.writeImage(writer, hook_ctx.at(url.ptr), url);
                    try blocks.popTag(writer, .figure);
                },
                .@"[^x]: " => |label| {
                    footnote_label = label;
                    try blocks.push(writer, .footnote_ol);
                },
                .@"| " => try blocks.append(writer, .{ .table, .tr, .th }),
                .text => |text| try writer.writeAll(text),
                .@"<" => try writer.writeAll("&lt;"),
                .@"&" => try writer.writeAll("&amp;"),
                .@"\\x" => |char| try writer.writeByte(char),
                .@"[^x]" => |number| if (!options.first_block_only)
                    try fmt.format(writer,
                        \\<sup id="fnref:{0s}"><a href="#fn:{0s}">{0s}</a></sup>
                    , .{number}),
                ._ => try inlines.toggle(writer, .em),
                .@"**" => try inlines.toggle(writer, .strong),
                .@"`" => try inlines.toggle(writer, .code),
                inline .@"[...](x)", .@"[...][x]" => |url_or_label, tag| {
                    const url = try maybeLookupUrl(tokenizer.scanner, links, url_or_label, tag);
                    try writer.writeAll("<a href=\"");
                    try hooks.writeUrl(writer, hook_ctx.at(url.ptr), url);
                    try writer.writeAll("\">");
                    try inlines.pushWithoutWriting(.a);
                },
                .@"]" => if (inlines.top() == .a) {
                    try inlines.pop(writer);
                } else {
                    try blocks.popTag(writer, .figcaption);
                    try blocks.popTag(writer, .figure);
                },
                .@" | " => {
                    const block = blocks.top().?;
                    assert(block == .td or block == .th);
                    try block.writeCloseTag(writer);
                    try block.writeOpenTag(writer);
                },
                .lsquo => try writer.writeAll("‘"),
                .rsquo => try writer.writeAll("’"),
                .ldquo => try writer.writeAll("“"),
                .rdquo => try writer.writeAll("”"),
                .@"--" => try writer.writeAll("–"), // en dash
                .@" -- " => try writer.writeAll("—"), // em dash
                .@"..." => try writer.writeAll("…"),
            }
            token = tokenizer.next(false);
        }
        if (inlines.top()) |tag| return tokenizer.fail("unclosed <{s}> tag", .{@tagName(tag)});
        if (options.first_block_only) break;
    }
    assert(inlines.len() == 0);
    if (highlighter.active) return tokenizer.fail("missing closing ```", .{});
    try blocks.truncate(writer, 0);
}

fn expectRenderSuccess(expected_html: []const u8, source: []const u8, options: Options) !void {
    try expectRenderSuccessWithHooks(expected_html, source, options, .{});
}

fn expectRenderSuccessWithHooks(expected_html: []const u8, source: []const u8, options: Options, hooks: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const markdown = try parse(allocator, &scanner);
    var actual_html = std.ArrayList(u8).init(allocator);
    try markdown.render(&reporter, actual_html.writer(), hooks, options);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectRenderFailure(expected_message: []const u8, source: []const u8, options: Options) !void {
    try expectRenderFailureWithHooks(expected_message, source, options, .{});
}

fn expectRenderFailureWithHooks(expected_message: []const u8, source: []const u8, options: Options, hooks: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const markdown = try parse(allocator, &scanner);
    try reporter.expectFailure(
        expected_message,
        markdown.render(&reporter, std.io.null_writer, hooks, options),
    );
}

test "render empty string" {
    try expectRenderSuccess("", "", .{});
    try expectRenderSuccess("", "", .{ .is_inline = true });
    try expectRenderSuccess("", "", .{ .first_block_only = true });
    try expectRenderSuccess("", "", .{ .is_inline = true, .first_block_only = true });
}

test "render text" {
    try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{});
    try expectRenderSuccess("Hello world!", "Hello world!", .{ .is_inline = true });
    try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{ .first_block_only = true });
    try expectRenderSuccess("Hello world!", "Hello world!", .{ .is_inline = true, .first_block_only = true });
}

test "render first block only" {
    const source =
        \\This is the first paragraph.
        \\
        \\This is the second paragraph.
    ;
    try expectRenderSuccess("<p>This is the first paragraph.</p>", source, .{ .first_block_only = true });
    try expectRenderSuccess("This is the first paragraph.", source, .{ .is_inline = true, .first_block_only = true });
}

test "render first block only with gap" {
    const source =
        \\
        \\This is the first paragraph.
        \\
        \\This is the second paragraph.
    ;
    try expectRenderSuccess("<p>This is the first paragraph.</p>", source, .{ .first_block_only = true });
    try expectRenderSuccess("This is the first paragraph.", source, .{ .is_inline = true, .first_block_only = true });
}

test "render backslash at end" {
    try expectRenderSuccess("<p>\\</p>", "\\", .{});
    try expectRenderSuccess("<p>Foo\\</p>", "Foo\\", .{});
}

test "render backslash scapes" {
    try expectRenderSuccess(
        \\<p># _nice_ `stuff` \</p>
    ,
        \\\# \_nice\_ \`stuff\` \\
    , .{});
}

test "render inline raw html" {
    try expectRenderSuccess("<p><cite>Foo</cite></p>", "<cite>Foo</cite>", .{});
}

test "render Markdown within raw inline html" {
    try expectRenderSuccess("<p><cite><em>Foo</em></cite></p>", "<cite>_Foo_</cite>", .{});
}

test "render entities" {
    try expectRenderSuccess("<p>1 + 1 &lt; 3, X>Y, AT&T</p>", "1 + 1 < 3, X>Y, AT&T", .{});
}

test "render raw entities" {
    try expectRenderSuccess("<p>I want a &dollar;</p>", "I want a &dollar;", .{});
}

test "render inline element after false raw inline html" {
    try expectRenderSuccess("<p>x&lt;y<em>z</em></p>", "x<y_z_", .{});
}

test "render inline element after false raw block html" {
    try expectRenderSuccess("<p>&lt;div jk not a <em>div</em></p>", "<div jk not a _div_", .{});
}

test "render raw block html" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<p><em>Before</em></p>
        \\<block>
        \\<em>After (part of block)</em>
    ,
        \\_Before_
        \\<block>
        \\_After (part of block)_
    , .{});
}

test "render text after exiting raw block html" {
    try expectRenderSuccess(
        \\<block>
        \\<p>After (not part of block)</p>
    ,
        \\<block>
        \\
        \\After (not part of block)
    , .{});
}

test "render text before and after exiting raw block html" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<block>
        \\<em>After (part of block)</em>
        \\<p><em>After (not part of block)</em></p>
    ,
        \\<block>
        \\_After (part of block)_
        \\
        \\_After (not part of block)_
    , .{});
}

test "render raw block html with inline elements" {
    try expectRenderSuccess(
        \\<div id="foo">
        \\Just in a <strong>div</strong>.
        \\</div>
    ,
        \\<div id="foo">
        \\Just in a **div**.
        \\</div>
    , .{});
}

test "render raw block html with nested paragraph" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess("<p><code>foo_bar</code></p>", "`foo_bar`", .{});
}

test "render code with backslash" {
    try expectRenderSuccess("<p><code>\\newline</code></p>", "`\\newline`", .{});
}

test "render code with entities" {
    try expectRenderSuccess("<p><code>&lt;foo> &amp;amp;</code></p>", "`<foo> &amp;`", .{});
}

test "render emphasis" {
    try expectRenderSuccess("<p>Hello <em>world</em>!</p>", "Hello _world_!", .{});
}

test "render strong" {
    try expectRenderSuccess("<p>Hello <strong>world</strong>!</p>", "Hello **world**!", .{});
}

test "render nested inlines" {
    try expectRenderSuccess(
        \\<p>a <strong>b <em>c <code>d</code> e</em> f</strong> g</p>
    ,
        \\a **b _c `d` e_ f** g
    , .{});
}

test "render inline link" {
    try expectRenderSuccess("<p><a href=\"#bar\">foo</a></p>", "[foo](#bar)", .{});
}

test "render reference link" {
    try expectRenderSuccess(
        \\<p>Look at <a href="https://example.com">foo</a>.</p>
    ,
        \\Look at [foo][bar].
        \\
        \\[bar]: https://example.com
    , .{});
}

test "render shortcut reference link" {
    try expectRenderSuccess(
        \\<p>Look at <a href="https://example.com">foo</a>.</p>
    ,
        \\Look at [foo].
        \\
        \\[foo]: https://example.com
    , .{});
}

test "render link with escaped brackets" {
    try expectRenderSuccess(
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
    try expectRenderSuccess("<h1>This is h1</h1>", "# This is h1", .{});
}

test "render all headings" {
    try expectRenderSuccess(
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
    try expectRenderSuccess("<p>#1</p>", "#1", .{});
}

test "render heading with multiple spaces" {
    try expectRenderSuccess("<h1>  X</h1>", "#   X", .{});
}

test "render inline after false heading" {
    try expectRenderSuccess("<p>####### <em>hi</em></p>", "####### _hi_", .{});
}

test "render heading id" {
    try expectRenderSuccess(
        \\<h1 id="this-is-h1">This is h1</h1>
        \\<h6 id="this-is-h6">This is h6</h6>
        \\<h2 id="abcxyz-abcxyz-0123456789">abcxyz ABCXYZ 0123456789</h2>
        \\<h2 id="cool-stuff"><strong>Cool</strong> <em>stuff</em></h2>
    ,
        \\# This is h1
        \\###### This is h6
        \\## abcxyz ABCXYZ 0123456789
        \\## **Cool** _stuff_
    , .{ .auto_heading_ids = true });
}

test "render shifted heading (positive)" {
    try expectRenderSuccess("<h2>Foo</h2>", "# Foo", .{ .shift_heading_level = 1 });
    try expectRenderSuccess("<h3>Foo</h3>", "## Foo", .{ .shift_heading_level = 1 });
    try expectRenderSuccess("<h6>Foo</h6>", "###### Foo", .{ .shift_heading_level = 1 });
}

test "render shifted heading (negative)" {
    try expectRenderSuccess("<h1>Foo</h1>", "# Foo", .{ .shift_heading_level = -1 });
    try expectRenderSuccess("<h1>Foo</h1>", "## Foo", .{ .shift_heading_level = -1 });
    try expectRenderSuccess("<h5>Foo</h5>", "###### Foo", .{ .shift_heading_level = -1 });
}

test "render false block inside heading" {
    try expectRenderSuccess("<h1>> Not a blockquote</h1>", "# > Not a blockquote", .{});
}

test "render unordered list" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<ol>
        \\<li>Apples</li>
        \\<li>Oranges</li>
        \\</ol>
        \\<ul>
        \\<li>other <strong>stuff</strong></li>
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

test "render two thematic breaks" {
    try expectRenderSuccess("<hr>\n<hr>", "* * *\n* * *", .{});
}

test "render three asterisks with text after" {
    try expectRenderSuccess("<p>* * *foo</p>", "* * *foo", .{});
}

test "render two thematic breaks in blockquote" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<blockquote>
        \\<p>Hi</p>
        \\</blockquote>
    ,
        \\> Hi
        \\>
    , .{});
}

test "render a few things" {
    try expectRenderSuccess(
        \\<h1>Hello <strong>world</strong>!</h1>
        \\<p>Here is <em>some</em> text.</p>
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
    try expectRenderSuccess(
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

test "render code block" {
    try expectRenderSuccess("<pre>\n<code>Foo</code>\n</pre>", "```\nFoo\n```", .{});
}

test "render code block with language but no highlighting" {
    try expectRenderSuccess("<pre>\n<code>Foo</code>\n</pre>", "```html\nFoo\n```", .{});
}

test "render code block with blank lines" {
    try expectRenderSuccess("<pre>\n<code>\n\n</code>\n</pre>", "```\n\n\n\n```", .{});
}

test "render code block with special characters" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<pre>
        \\<code>```not the end</code>
        \\</pre>
    ,
        \\```
        \\```not the end
        \\```
    , .{});
}

test "render code block in blockquote" {
    try expectRenderSuccess(
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
    try expectRenderFailure("<input>:1:4: missing closing ```", "```", .{});
}

test "unclosed code block in blockquote" {
    try expectRenderFailure("<input>:1:6: missing closing ```", "> ```", .{});
}

test "unclosed code block in blockquote with text after" {
    try expectRenderFailure("<input>:2:1: missing closing ```", "> ```\n\nFoo", .{});
}

test "render smart typography" {
    try expectRenderSuccess(
        \\<p>This—“that isn’t 1–2” … other.</p>
    ,
        \\This -- "that isn't 1--2" ... other.
    , .{});
}

test "render space-aware smart typography when space is already consumed" {
    try expectRenderSuccess("<h1>– en dash not em</h1>", "# -- en dash not em", .{});
}

test "render footnotes" {
    try expectRenderSuccess(
        \\<p>Foo<sup id="fnref:1"><a href="#fn:1">1</a></sup>.</p>
        \\<p>Bar<sup id="fnref:2"><a href="#fn:2">2</a></sup>.</p>
        \\<hr>
        \\<ol class="footnotes">
        \\<li id="fn:1"><em>first</em>&nbsp;<a href="#fnref:1">↩︎</a></li>
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

test "no footnotes if first block only" {
    try expectRenderSuccess(
        \\<p>Foo.</p>
    ,
        \\Foo[^1].
        \\[^1]: second
    , .{ .first_block_only = true });
}

test "render figure (url)" {
    try expectRenderSuccess(
        \\<figure>
        \\<img src="rabbit.jpg">
        \\<figcaption>Some caption</figcaption>
        \\</figure>
    ,
        \\![Some caption](rabbit.jpg)
    , .{});
}

test "render figure (reference)" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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

test "render figure with link in caption" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<figure>
        \\<figcaption>Some caption</figcaption>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![^Some caption](rabbit.jpg)
    , .{});
}

test "render top-caption figure (reference)" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<figure>
        \\<figcaption>Some caption</figcaption>
        \\<img src="">
        \\</figure>
    ,
        \\![^Some caption]
    , .{});
}

test "render top-caption figure with link in caption" {
    try expectRenderSuccess(
        \\<figure>
        \\<figcaption>Some <a href="foo">caption</a> here</figcaption>
        \\<img src="rabbit.jpg">
        \\</figure>
    ,
        \\![^Some [caption] here](rabbit.jpg)
        \\[caption]: foo
    , .{});
}

test "render false figure inline" {
    try expectRenderSuccess("<p>Not !<a href=\"x\">figure</a></p>", "Not ![figure](x)", .{});
}

test "render unbalanced right bracket" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(html, "|", .{});
    try expectRenderSuccess(html, "||", .{});
    try expectRenderSuccess(html, "| |", .{});
    try expectRenderSuccess(html, "|  |", .{});
}

test "render basic table" {
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess(
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
    try expectRenderSuccess(
        \\<table>
        \\<tr><th>x</th><th>y</th></tr>
        \\<tr><td>z</td><td>w</td></tr>
        \\</table>
    ,
        \\| x | y
        \\| z | w
    , .{});
}

test "unclosed inline at end" {
    try expectRenderFailure(
        \\<input>:1:5: unclosed <em> tag
    ,
        \\_foo
    , .{});
}

test "unclosed inline in middle" {
    try expectRenderFailure(
        \\<input>:1:15: unclosed <strong> tag
    ,
        \\> Some **stuff
        \\
        \\And more.
    , .{});
}

test "unclosed inline code" {
    try expectRenderFailure(
        \\<input>:1:6: unclosed <code> tag
    ,
        \\`nice
        \\foo`
    , .{});
}

test "exceed max inline tag depth" {
    try expectRenderFailure(
        \\<input>:1:21: exceeded maximum tag depth (8)
    ,
        \\_ ** _ ** _ ** _ ** `
    , .{});
}

test "exceed max inline tag depth with link" {
    try expectRenderFailure(
        \\<input>:1:21: exceeded maximum tag depth (8)
    ,
        \\_ ** _ ** _ ** _ ** [foo](bar)
    , .{});
}

test "exceed max block tag depth" {
    try expectRenderFailure(
        \\<input>:1:17: exceeded maximum tag depth (8)
    ,
        \\> > > > > > > > -
    , .{});
}

test "writeUrl hook" {
    const hooks = struct {
        data: []const u8 = "data",
        fn writeUrl(self: @This(), writer: anytype, context: HookContext, url: []const u8) !void {
            try fmt.format(writer, "hook got {s} in {s}, can access {s}", .{ url, context.filename, self.data });
        }
    }{};
    try expectRenderSuccessWithHooks(
        \\<p><a href="hook got #foo in <input>, can access data">text</a></p>
    ,
        \\[text](#foo)
    , .{}, hooks);
}

test "failure in writeUrl hook (inline)" {
    const hooks = struct {
        fn writeUrl(self: @This(), writer: anytype, context: HookContext, url: []const u8) !void {
            _ = writer;
            _ = self;
            return context.fail("{s}: bad url", .{url});
        }
    }{};
    try expectRenderFailureWithHooks(
        \\<input>:1:18: xyz: bad url
    ,
        \\[some link text](xyz)
    , .{}, hooks);
}

test "failure in writeUrl hook (reference)" {
    const hooks = struct {
        fn writeUrl(self: @This(), writer: anytype, context: HookContext, url: []const u8) !void {
            _ = writer;
            _ = self;
            return context.fail("{s}: bad url", .{url});
        }
    }{};
    try expectRenderFailureWithHooks(
        \\<input>:3:8: xyz: bad url
    ,
        \\[some
        \\link text][ref]
        \\[ref]: xyz
    , .{}, hooks);
}
