// Copyright 2023 Mitchell Kember. Subject to the MIT License.

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
const Span = Scanner.Span;
const Markdown = @This();

span: Span,
context: Context,

pub const Context = struct {
    filename: []const u8,
    links: LinkMap,
};

pub const LinkMap = std.StringHashMapUnmanaged([]const u8);

pub fn parse(allocator: Allocator, scanner: *Scanner) !Markdown {
    var links = LinkMap{};
    var source = scanner.source[scanner.offset..];
    outer: while (true) {
        source = std.mem.trimRight(u8, source, "\n");
        const newline_index = std.mem.lastIndexOfScalar(u8, source, '\n') orelse break;
        var i = newline_index + 1;
        if (i == source.len or source[i] != '[') break;
        i += 1;
        if (i == source.len or source[i] == '^') break;
        const label_start = i;
        while (i < source.len) : (i += 1) switch (source[i]) {
            '\n' => break :outer,
            ']' => break,
            else => {},
        };
        const label_end = i;
        i += 1;
        if (i == source.len or source[i] != ':') break;
        i += 1;
        if (i == source.len or source[i] != ' ') break;
        i += 1;
        try links.put(allocator, source[label_start..label_end], source[i..]);
        source.len = newline_index;
    }
    return Markdown{
        .span = Span{ .text = source, .location = scanner.location },
        .context = Context{ .filename = scanner.filename, .links = links },
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
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const md = try parse(allocator, &scanner);
    try testing.expectEqualStrings(
        \\This is the body.
        \\
        \\[This is not a link]
    , md.span.text);
    try testing.expectEqualDeep(Location{}, md.span.location);
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
    try testing.expectEqualStrings("This is the body.", md.span.text);
    try testing.expectEqual(@as(usize, 2), md.context.links.size);
    try testing.expectEqualStrings("foo link", md.context.links.get("foo").?);
    try testing.expectEqualStrings("bar baz link", md.context.links.get("bar baz").?);
}

const Token = struct {
    value: TokenValue,
    location: Location,
};

const TokenValue = union(enum) {
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
    @"[^x]: ": []const u8,
    // TODO: figures, tables

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
    lsquo,
    rsquo,
    ldquo,
    rdquo,
    @"--",
    @" -- ",
    @"...",

    // Used for both block and inline
    @"]",

    fn is_inline(self: TokenValue) bool {
        return @intFromEnum(self) >= @intFromEnum(TokenValue.text);
    }
};

const Tokenizer = struct {
    scanner: *Scanner,
    peeked: ?Token = null,
    // Be careful reading these values outside the Tokenizer, since they might
    // pertain to the peeked token, not the current one.
    block_allowed: bool = true,
    in_inline_code: bool = false,
    in_raw_html_block: bool = false,
    link_depth: u8 = 0,

    fn init(scanner: *Scanner) !Tokenizer {
        while (scanner.peek(0)) |c| if (c == '\n') scanner.eat(c) else break;
        return Tokenizer{ .scanner = scanner };
    }

    fn fail(self: Tokenizer, comptime format: []const u8, args: anytype) Reporter.Error {
        const location = if (self.peeked) |token| token.location else self.scanner.location;
        return self.scanner.failAt(location, format, args);
    }

    fn failOn(self: Tokenizer, token: Token, comptime format: []const u8, args: anytype) Reporter.Error {
        return self.scanner.failAt(token.location, format, args);
    }

    fn handle(self: *const Tokenizer, token: Token) Handle {
        return Handle{ .tokenizer = self, .location = token.location };
    }

    // Returns the remaining untokenized source.
    // This is inaccurate when there is a peeked token (i.e. after next() returns text).
    fn remaining(self: Tokenizer) []const u8 {
        return self.scanner.source[self.scanner.offset..];
    }

    fn next(self: *Tokenizer, in_code_block: bool) !Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        const scanner = self.scanner;
        const start_offset = scanner.offset;
        const start_location = scanner.location;
        const result = try self.nextNonText(in_code_block);
        const text = scanner.source[start_offset..result.offset];
        if (text.len == 0) return result.token;
        self.peeked = result.token;
        return Token{ .value = .{ .text = text }, .location = start_location };
    }

    fn nextNonText(self: *Tokenizer, in_code_block: bool) !struct { token: Token, offset: usize } {
        const scanner = self.scanner;
        var location: Location = undefined;
        var offset: usize = undefined;
        // TODO don't need blk?
        const value: TokenValue = blk: while (true) {
            location = scanner.location;
            offset = scanner.offset;
            if (in_code_block) {
                if (scanner.eof()) break :blk .eof;
                if (scanner.peek(0) == '`' and scanner.peek(1) == '`' and scanner.peek(2) == '`' and (scanner.peek(3) == '\n' or scanner.peek(3) == null)) {
                    scanner.eat('`');
                    scanner.eat('`');
                    scanner.eat('`');
                    _ = scanner.next();
                    break :blk .@"```\n";
                }
                break :blk .stay_in_code_block;
            }
            const char = scanner.next() orelse break :blk .eof;
            if (self.block_allowed) switch (char) {
                '#' => {
                    const level: u8 = @intCast(1 + scanner.eatWhile('#'));
                    if (level <= 6 and scanner.eatIf(' ')) break :blk .{ .@"#" = level };
                },
                '<' => if (scanner.peek(0)) |c| switch (c) {
                    '/', 'a'...'z' => {
                        var i: usize = 1;
                        while (scanner.peek(i)) |ch| : (i += 1) if (ch == '>') break;
                        if (scanner.peek(i) == '>') {
                            i += 1;
                            const ch = scanner.peek(i);
                            if (ch == null or ch == '\n') {
                                _ = try scanner.consume(i);
                                self.in_raw_html_block = true;
                                // Need to make a separate text token, rather than just
                                // `continue` as we do for inline HTML, so that when the
                                // user checks `in_raw_html_block` it's accurate.
                                break :blk .{ .text = scanner.source[offset..scanner.offset] };
                            }
                        }
                    },
                    else => {},
                },
                '>' => if (scanner.eatIf(' ') or scanner.peek(0) == '\n' or scanner.eof()) break :blk .@">",
                '`' => if (scanner.peek(0) == '`' and scanner.peek(1) == '`') {
                    scanner.eat('`');
                    scanner.eat('`');
                    var start = scanner.offset;
                    var end = start;
                    while (scanner.next()) |ch| if (ch == '\n') {
                        break;
                    } else {
                        end += 1;
                    };
                    break :blk .{ .@"```x\n" = scanner.source[start..end] };
                },
                '$' => if (scanner.eatIf('$')) {
                    // TODO: This is temporary, to avoid interpreting math as Markdown.
                    _ = try scanner.until('$');
                    try scanner.expect("$");
                    break :blk .{ .text = scanner.source[offset..scanner.offset] };
                },
                '-' => if (scanner.eatIf(' ')) break :blk .@"-",
                '1'...'9' => {
                    var i: usize = 0;
                    while (scanner.peek(i)) |c| : (i += 1) switch (c) {
                        '0'...'9' => {},
                        '.' => {
                            i += 1;
                            if (scanner.peek(i) == ' ') {
                                _ = try scanner.consume(i + 1);
                                break :blk .@"1.";
                            }
                        },
                        else => break,
                    };
                },
                '*' => if (scanner.attempt(" * *") and (scanner.eof() or scanner.eatIf('\n')))
                    break :blk .@"* * *\n",
                '[' => if (scanner.eatIf('^')) {
                    const span = try scanner.until(']');
                    // TODO: maybe shouldn't be an error here.
                    try scanner.expect(": ");
                    break :blk .{ .@"[^x]: " = span.text };
                },
                else => {},
            };
            self.block_allowed = false;
            switch (char) {
                '\n' => {
                    if (scanner.eatWhile('\n') > 0) self.in_raw_html_block = false;
                    break :blk .@"\n";
                },
                '`' => {
                    self.in_inline_code = !self.in_inline_code;
                    break :blk .@"`";
                },
                '<' => {
                    if (!self.in_inline_code) if (scanner.peek(0)) |c| switch (c) {
                        '/', 'a'...'z' => {
                            _ = try scanner.until('>');
                            continue;
                        },
                        else => {},
                    };
                    break :blk .@"<";
                },
                // Only escape ampersands in inline code. If regular text contains something
                // that parses as an entity, you probably actually wanted an entity.
                '&' => if (self.in_inline_code) break :blk .@"&",
                else => if (self.in_inline_code) continue,
            }
            switch (char) {
                '\\' => if (scanner.next()) |c| break :blk .{ .@"\\x" = c },
                '$' => {
                    // TODO: This is temporary, to avoid interpreting math as Markdown.
                    _ = try scanner.until('$');
                    break :blk .{ .text = scanner.source[offset..scanner.offset] };
                },
                '[' => link: {
                    if (scanner.eatIf('^')) {
                        const span = try scanner.until(']');
                        break :blk .{ .@"[^x]" = span.text };
                    }
                    const after_lbracket = offset;
                    const is_image = scanner.behind(2) == '!';
                    if (is_image) {
                        offset -= 1;
                        location.column -= 1;
                    }
                    var i: usize = 0;
                    var escaped = false;
                    var in_code = false;
                    var depth: usize = 1;
                    while (true) : (i += 1) {
                        const ch = scanner.peek(i) orelse break :link;
                        if (escaped) {
                            escaped = false;
                        } else if (in_code) {
                            if (ch == '`') in_code = false;
                        } else switch (ch) {
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
                    const closing_char: u8 = switch (scanner.peek(i + 1) orelse 0) {
                        '(' => ')',
                        '[' => ']',
                        else => {
                            const end_of_text = scanner.offset + i;
                            const label = scanner.source[after_lbracket + 1 .. end_of_text];
                            self.link_depth += 1;
                            break :blk if (is_image) .{ .@"![...][x]" = label } else .{ .@"[...][x]" = label };
                        },
                    };
                    i += 2;
                    const start_of_url = scanner.offset + i;
                    const start_of_url_location = scanner.peekLocation(i);
                    while (scanner.peek(i)) |ch| : (i += 1) if (ch == closing_char) break;
                    if (scanner.peek(i) != closing_char) break :link;
                    const closing_paren = scanner.offset + i;
                    i += 1;
                    location = start_of_url_location;
                    const url_or_label = scanner.source[start_of_url..closing_paren];
                    self.link_depth += 1;
                    break :blk switch (closing_char) {
                        ')' => if (is_image) .{ .@"![...](x)" = url_or_label } else .{ .@"[...](x)" = url_or_label },
                        ']' => if (is_image) .{ .@"![...][x]" = url_or_label } else .{ .@"[...][x]" = url_or_label },
                        else => unreachable,
                    };
                },
                ']' => {
                    if (self.link_depth == 0) return scanner.failAt(location, "unexpected ']'", .{});
                    self.link_depth -= 1;
                    if (scanner.peek(0)) |c| switch (c) {
                        '(' => _ = try scanner.until(')'),
                        '[' => _ = try scanner.until(']'),
                        else => {},
                    };
                    break :blk .@"]";
                },
                '*' => if (scanner.eatIf('*')) break :blk .@"**",
                '_' => break :blk ._,
                '\'' => {
                    const prev = scanner.behind(2);
                    break :blk if (prev == null or prev == ' ' or prev == '\n') .lsquo else .rsquo;
                },
                '"' => {
                    const prev = scanner.behind(2);
                    break :blk if (prev == null or prev == ' ' or prev == '\n') .ldquo else .rdquo;
                },
                '-' => if (scanner.eatIf('-')) {
                    // Look backwards for the space in " -- " instead of checking for
                    // "-- " after any space, because spaces are much more common.
                    if (scanner.behind(3) == ' ' and scanner.eatIf(' ')) {
                        offset -= 1;
                        location.column -= 1;
                        break :blk .@" -- ";
                    }
                    break :blk .@"--";
                },
                '.' => if (scanner.attempt("..")) break :blk .@"...",
                else => {},
            }
        };
        switch (value) {
            .@"\n", .@">" => self.block_allowed = true,
            else => {},
        }
        return .{
            .token = .{ .value = value, .location = location },
            .offset = offset,
        };
    }
};

fn expectTokens(expected: []const TokenValue, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = try Tokenizer.init(&scanner);
    var actual = std.ArrayList(TokenValue).init(allocator);
    while (true) {
        const token = try tokenizer.next(false);
        try actual.append(token.value);
        if (token.value == .eof) break;
    }
    try testing.expectEqualDeep(expected, actual.items);
}

test "tokenize empty string" {
    try expectTokens(&[_]TokenValue{.eof}, "");
}

test "tokenize text" {
    try expectTokens(&[_]TokenValue{ .{ .text = "Hello world!" }, .eof }, "Hello world!");
}

test "tokenize inline" {
    try expectTokens(&[_]TokenValue{
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
    try expectTokens(&[_]TokenValue{
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
    try expectTokens(&[_]TokenValue{
        .{ .@"[...](x)" = "bar" },
        .{ .text = "foo" },
        .@"]",
        .eof,
    },
        \\[foo](bar)
    );
}

test "tokenize figure" {
    try expectTokens(&[_]TokenValue{
        .{ .@"![...](x)" = "bar" },
        .{ .text = "Foo" },
        .@"]",
        .eof,
    },
        \\![Foo](bar)
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

        fn writeUrl(self: Self, writer: anytype, handle: Handle, url: []const u8) !void {
            if (@hasDecl(Underlying, "writeUrl")) return self.inner.writeUrl(writer, handle, url);
            try writer.writeAll(url);
        }

        fn writeImage(self: Self, writer: anytype, handle: Handle, url: []const u8) !void {
            if (@hasDecl(Underlying, "writeImage")) return self.inner.writeImage(writer, handle, url);
            try fmt.format(writer, "<img src=\"{s}\">", .{url});
        }
    };
}

// TODO maybe rename
pub const Handle = struct {
    tokenizer: *const Tokenizer,
    location: Location,

    pub fn filename(self: Handle) []const u8 {
        return self.tokenizer.scanner.filename;
    }

    pub fn fail(self: Handle, comptime format: []const u8, args: anytype) Reporter.Error {
        return self.tokenizer.scanner.failAt(self.location, format, args);
    }
};

pub fn render(
    self: Markdown,
    reporter: *Reporter,
    writer: anytype,
    hooks: anytype,
    options: Options,
) !void {
    var scanner = Scanner{
        .source = self.span.text,
        .reporter = reporter,
        .filename = self.context.filename,
        .location = self.span.location,
    };
    var tokenizer = try Tokenizer.init(&scanner);
    const full_hooks = WithDefaultHooks(@TypeOf(hooks)){ .inner = hooks };
    return renderImpl(&tokenizer, writer, full_hooks, self.context.links, options) catch |err| switch (err) {
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

        fn pop(self: *Self, writer: anytype) !void {
            try self.items.pop().writeCloseTag(writer);
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
    // TODO reorder these
    p,
    li,
    footnote_li: []const u8,
    // I'm making this fit in 8 bytes just because I can.
    h: struct { source: ?[*]const u8, source_len: u32, level: u8 },
    figcaption,
    ul,
    ol,
    footnote_ol,
    blockquote,
    figure,

    fn heading(source: []const u8, level: u8, options: Options) BlockTag {
        const adjusted = @as(i8, @intCast(level)) + options.shift_heading_level;
        return BlockTag{
            .h = .{
                .source = if (options.auto_heading_ids) source.ptr else null,
                .source_len = @intCast(source.len),
                .level = @intCast(std.math.clamp(adjusted, 1, 6)),
            },
        };
    }

    fn implicitChild(parent: ?BlockTag, footnote_label: ?[]const u8) ?BlockTag {
        return switch (parent orelse return .p) {
            .ul, .ol => .li,
            .footnote_ol => .{ .footnote_li = footnote_label.? },
            .blockquote => .p,
            else => null,
        };
    }

    fn goesOnItsOwnLine(self: BlockTag) bool {
        return switch (self) {
            .p, .li, .footnote_li, .h, .figcaption => false,
            .ul, .ol, .footnote_ol, .blockquote, .figure => true,
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

fn maybeLookupUrl(tokenizer: *const Tokenizer, token: Token, links: LinkMap, url_or_label: []const u8, tag: std.meta.Tag(TokenValue)) ![]const u8 {
    return switch (tag) {
        .@"[...](x)", .@"![...](x)" => url_or_label,
        .@"[...][x]", .@"![...][x]" => links.get(url_or_label) orelse
            tokenizer.failOn(token, "link label '{s}' is not defined", .{url_or_label}),
        else => unreachable,
    };
}

fn renderImpl(tokenizer: *Tokenizer, writer: anytype, hooks: anytype, links: LinkMap, options: Options) !void {
    var blocks = Stack(BlockTag){};
    var inlines = Stack(InlineTag){};
    var highlighter = Highlighter{ .enabled = options.highlight_code };
    var footnote_label: ?[]const u8 = null;
    var first_iteration = true;
    while (true) {
        var num_blocks_open: usize = 0;
        var all_open = num_blocks_open == blocks.len();
        var token = try tokenizer.next(all_open and highlighter.active);
        while (!all_open) {
            switch (blocks.get(num_blocks_open)) {
                .p, .li, .footnote_li, .h, .figcaption, .figure => break,
                .ul => if (token.value != .@"-") break,
                .ol => if (token.value != .@"1.") break,
                .footnote_ol => switch (token.value) {
                    .@"[^x]: " => |label| footnote_label = label,
                    else => break,
                },
                .blockquote => if (token.value != .@">") break,
            }
            num_blocks_open += 1;
            all_open = num_blocks_open == blocks.len();
            token = try tokenizer.next(all_open and highlighter.active);
        }
        if (token.value == .eof) break;
        if (highlighter.active) {
            if (!all_open) return tokenizer.failOn(token, "missing closing ```", .{});
            switch (token.value) {
                .stay_in_code_block => try highlighter.renderLine(writer, tokenizer.scanner),
                .@"```\n" => try highlighter.end(writer),
                else => unreachable,
            }
            continue;
        }
        try blocks.truncate(writer, num_blocks_open);
        if (token.value == .@"\n") continue;
        if (!first_iteration) try writer.writeByte('\n');
        first_iteration = false;
        var need_implicit_block = !options.is_inline;
        while (true) {
            if (need_implicit_block and token.value.is_inline()) {
                if (!(tokenizer.in_raw_html_block and blocks.len() == 0))
                    if (BlockTag.implicitChild(blocks.top(), footnote_label)) |block|
                        try blocks.push(writer, block);
                need_implicit_block = false;
            }
            switch (token.value) {
                .eof, .@"\n" => break,
                .@"* * *\n" => break try writer.writeAll("<hr>"),
                .@"```x\n" => |language| break try highlighter.begin(writer, Language.from(language)),
                .stay_in_code_block, .@"```\n" => unreachable,
                .@"#" => |level| {
                    const tag = BlockTag.heading(tokenizer.remaining(), level, options);
                    try blocks.push(writer, tag);
                },
                .@"-" => try blocks.push(writer, .ul),
                .@"1." => try blocks.push(writer, .ol),
                .@">" => try blocks.push(writer, .blockquote),
                inline .@"![...](x)", .@"![...][x]" => |url_or_label, tag| {
                    const url = try maybeLookupUrl(tokenizer, token, links, url_or_label, tag);
                    try blocks.push(writer, .figure);
                    try hooks.writeImage(writer, tokenizer.handle(token), url);
                    try writer.writeByte('\n');
                    try blocks.push(writer, .figcaption);
                },
                .@"[^x]: " => |label| {
                    footnote_label = label;
                    try blocks.push(writer, .footnote_ol);
                },
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
                    const url = try maybeLookupUrl(tokenizer, token, links, url_or_label, tag);
                    try writer.writeAll("<a href=\"");
                    try hooks.writeUrl(writer, tokenizer.handle(token), url);
                    try writer.writeAll("\">");
                    try inlines.pushWithoutWriting(.a);
                },
                .@"]" => if (inlines.top() == .a) {
                    try inlines.pop(writer);
                } else {
                    assert(std.meta.activeTag(blocks.top().?) == .figcaption);
                    try blocks.pop(writer);
                    assert(std.meta.activeTag(blocks.top().?) == .figure);
                    try blocks.pop(writer);
                },
                .lsquo => try writer.writeAll("‘"),
                .rsquo => try writer.writeAll("’"),
                .ldquo => try writer.writeAll("“"),
                .rdquo => try writer.writeAll("”"),
                .@"--" => try writer.writeAll("–"), // en dash
                .@" -- " => try writer.writeAll("—"), // em dash
                .@"..." => try writer.writeAll("…"),
            }
            token = try tokenizer.next(false);
        }
        if (inlines.top()) |tag| return tokenizer.failOn(token, "unclosed <{s}> tag", .{@tagName(tag)});
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

test "render raw block html" {
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

test "exceed max inline tag depth" {
    try expectRenderFailure(
        \\<input>:1:22: exceeded maximum tag depth (8)
    ,
        \\_ ** _ ** _ ** _ ** `
    , .{});
}

test "exceed max block tag depth" {
    try expectRenderFailure(
        \\<input>:1:18: exceeded maximum tag depth (8)
    ,
        \\> > > > > > > > -
    , .{});
}

test "unexpected right bracket" {
    try expectRenderFailure(
        \\<input>:1:6: unexpected ']'
    ,
        \\Some ] out of nowhere
    , .{});
}

test "writeUrl hook" {
    const hooks = struct {
        data: []const u8 = "data",
        fn writeUrl(self: @This(), writer: anytype, handle: Handle, url: []const u8) !void {
            try fmt.format(writer, "hook got {s} in {s}, can access {s}", .{ url, handle.filename(), self.data });
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
        fn writeUrl(self: @This(), writer: anytype, handle: Handle, url: []const u8) !void {
            _ = writer;
            _ = self;
            return handle.fail("{s}: bad url", .{url});
        }
    }{};
    try expectRenderFailureWithHooks(
        \\<input>:2:12: xyz: bad url
    ,
        \\[some
        \\link text](xyz)
    , .{}, hooks);
}

test "failure in writeUrl hook (reference)" {
    const hooks = struct {
        fn writeUrl(self: @This(), writer: anytype, handle: Handle, url: []const u8) !void {
            _ = writer;
            _ = self;
            return handle.fail("{s}: bad url", .{url});
        }
    }{};
    // It would be nicer to point to the actual "xyz", not the "ref".
    // We could do that by storing Span in LinkMap, but that would require a
    // full extra traversal to count newlines, which I don't want to do.
    try expectRenderFailureWithHooks(
        \\<input>:2:12: xyz: bad url
    ,
        \\[some
        \\link text][ref]
        \\[ref]: xyz
    , .{}, hooks);
}
