// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;
const Markdown = @This();

filename: []const u8,
body: Span,
links: LinkMap,

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
    const body = Span{ .text = source, .location = scanner.location };
    return Markdown{ .filename = scanner.filename, .body = body, .links = links };
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
    const doc = try parse(allocator, &scanner);
    try testing.expectEqualStrings(
        \\This is the body.
        \\
        \\[This is not a link]
    , doc.body.text);
    try testing.expectEqualDeep(Location{}, doc.body.location);
    try testing.expectEqual(@as(usize, 2), doc.links.size);
    try testing.expectEqualStrings("foo link", doc.links.get("foo").?);
    try testing.expectEqualStrings("bar baz link", doc.links.get("bar baz").?);
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
    const doc = try parse(allocator, &scanner);
    try testing.expectEqualStrings("This is the body.", doc.body.text);
    try testing.expectEqual(@as(usize, 2), doc.links.size);
    try testing.expectEqualStrings("foo link", doc.links.get("foo").?);
    try testing.expectEqualStrings("bar baz link", doc.links.get("bar baz").?);
}

const Token = struct {
    value: TokenValue,
    location: Location,
};

const TokenValue = union(enum) {
    // Blocks tokens
    @"\n",
    @"#": u8,
    @"-",
    @"1.",
    @">",
    @"* * *",
    @"```x": []const u8,
    @"```",
    // @"$$",
    @"[^x]: ": []const u8,
    // TODO: figures, tables

    // Inline tokens
    text: []const u8,
    @"<",
    @"&",
    escaped: u8,
    // @"$",
    @"[^x]": []const u8,
    _,
    @"**",
    @"`",
    @"[...](x)": []const u8,
    @"[...][x]": []const u8,
    @"]",
    @"‘",
    @"’",
    @"“",
    @"”",
    @"--",
    @" -- ",
    @"...",

    fn is_inline(self: TokenValue) bool {
        return @intFromEnum(self) >= @intFromEnum(TokenValue.text);
    }
};

const Tokenizer = struct {
    peeked: ?Token = null,
    // Be careful reading these values outside the Tokenizer, since they might
    // pertain to the peeked token, not the current one.
    block_allowed: bool = true,
    in_inline_code: bool = false,
    in_raw_html_block: bool = false,
    jump_over_link: ?struct { from: usize, to: usize } = null,

    fn init(scanner: *Scanner) !Tokenizer {
        while (scanner.peek(0)) |c| if (c == '\n') scanner.eat(c) else break;
        return Tokenizer{};
    }

    fn next(self: *Tokenizer, scanner: *Scanner) !?Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        const start_offset = scanner.offset;
        const start_location = scanner.location;
        if (try self.nextNonText(scanner)) |result| {
            if (result.offset == start_offset) return result.token;
            self.peeked = result.token;
            return Token{
                .value = .{ .text = scanner.source[start_offset..result.offset] },
                .location = start_location,
            };
        }
        if (scanner.offset == start_offset) return null;
        return Token{
            .value = .{ .text = scanner.source[start_offset..scanner.offset] },
            .location = start_location,
        };
    }

    fn nextNonText(self: *Tokenizer, scanner: *Scanner) !?struct { token: Token, offset: usize } {
        var location: Location = undefined;
        var offset: usize = undefined;
        const value: TokenValue = blk: while (true) {
            location = scanner.location;
            offset = scanner.offset;
            if (self.jump_over_link) |jump| if (scanner.offset == jump.from) {
                while (scanner.offset < jump.to) _ = scanner.next();
                self.jump_over_link = null;
                break :blk .@"]";
            };
            const char = scanner.next() orelse return null;
            // TODO: don't always have to peek, can consume if there is no need to backtrack
            if (self.block_allowed) switch (char) {
                '#' => {
                    var level: u8 = 1;
                    while (scanner.peek(0)) |c| switch (c) {
                        '#' => {
                            scanner.eat(c);
                            level += 1;
                        },
                        ' ' => {
                            scanner.eat(c);
                            break :blk .{ .@"#" = level };
                        },
                        else => break,
                    };
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
                '>' => {
                    while (scanner.peek(0)) |c| if (c == ' ') scanner.eat(c) else break;
                    break :blk .@">";
                },
                '`' => if (scanner.attempt("``")) {
                    const span = try scanner.until('\n');
                    _ = span;
                    // TODO: This is temporary, to avoid interpreting code as Markdown.
                    while (true) {
                        _ = try scanner.until('`');
                        if (scanner.attempt("``")) break;
                    }
                    break :blk .{ .text = scanner.source[offset..scanner.offset] };
                    // if (span.text.len == 0) break :blk .@"```";
                    // break :blk .{ .@"```x" = span.text };
                },
                '$' => if (scanner.attempt("$")) {
                    // TODO: This is temporary, to avoid interpreting math as Markdown.
                    _ = try scanner.until('$');
                    try scanner.expect("$");
                    break :blk .{ .text = scanner.source[offset..scanner.offset] };
                },
                '-' => if (scanner.peek(0) == ' ') {
                    _ = scanner.next();
                    break :blk .@"-";
                },
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
                '*' => if (scanner.attempt(" * *")) {
                    const c = scanner.peek(0);
                    if (c == null or c == '\n') break :blk .@"* * *";
                },
                '[' => if (scanner.peek(0) == '^') {
                    _ = scanner.next();
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
                    while (scanner.peek(0)) |c| if (c == '\n') {
                        scanner.eat(c);
                        self.in_raw_html_block = false;
                    } else {
                        break;
                    };
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
                '&' => if (self.in_inline_code) break :blk .@"&",
                else => if (self.in_inline_code) continue,
            }
            switch (char) {
                '\\' => if (scanner.next()) |c| break :blk .{ .escaped = c },
                '$' => {
                    // TODO: This is temporary, to avoid interpreting math as Markdown.
                    _ = try scanner.until('$');
                    break :blk .{ .text = scanner.source[offset..scanner.offset] };
                },
                '[' => if (scanner.peek(0) == '^') {
                    _ = scanner.next();
                    const span = try scanner.until(']');
                    break :blk .{ .@"[^x]" = span.text };
                } else {
                    var i: usize = 0;
                    while (scanner.peek(i)) |ch| : (i += 1) if (ch == ']') break;
                    if (scanner.peek(i) == ']' and scanner.peek(i + 1) == '(') {
                        const end_of_text = scanner.offset + i;
                        i += 2;
                        const start_of_url = scanner.offset + i;
                        while (scanner.peek(i)) |ch| : (i += 1) if (ch == ')') break;
                        if (scanner.peek(i) == ')') {
                            const closing_paren = scanner.offset + i;
                            i += 1;
                            const after_closing_paren = scanner.offset + i;
                            self.jump_over_link = .{ .from = end_of_text, .to = after_closing_paren };
                            break :blk .{ .@"[...](x)" = scanner.source[start_of_url..closing_paren] };
                        }
                    } else if (scanner.peek(i) == ']' and scanner.peek(i + 1) == '[') {
                        const end_of_text = scanner.offset + i;
                        i += 2;
                        const start_of_label = scanner.offset + i;
                        while (scanner.peek(i)) |ch| : (i += 1) if (ch == ']') break;
                        if (scanner.peek(i) == ']') {
                            const closing_bracket = scanner.offset + i;
                            i += 1;
                            const after_closing_bracket = scanner.offset + i;
                            self.jump_over_link = .{ .from = end_of_text, .to = after_closing_bracket };
                            break :blk .{ .@"[...][x]" = scanner.source[start_of_label..closing_bracket] };
                        }
                    } else if (scanner.peek(i) == ']') {
                        const end_of_text = scanner.offset + i;
                        self.jump_over_link = .{ .from = end_of_text, .to = end_of_text + 1 };
                        break :blk .{ .@"[...][x]" = scanner.source[offset + 1 .. end_of_text] };
                    }
                },
                '*' => if (scanner.peek(0) == '*') {
                    _ = scanner.next();
                    break :blk .@"**";
                },
                '_' => break :blk ._,
                '\'' => {
                    const prev = scanner.behind(2);
                    break :blk if (prev == null or prev == ' ' or prev == '\n') .@"‘" else .@"’";
                },
                '"' => {
                    const prev = scanner.behind(2);
                    break :blk if (prev == null or prev == ' ' or prev == '\n') .@"“" else .@"”";
                },
                '-' => if (scanner.peek(0) == '-') {
                    _ = scanner.next();
                    break :blk .@"--";
                },
                ' ' => if (scanner.attempt("-- ")) break :blk .@" -- ",
                '.' => if (scanner.attempt("..")) break :blk .@"...",
                else => {},
            }
        };
        switch (value) {
            .@"\n", .@">", .@"* * *" => self.block_allowed = true,
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
        .@"* * *",
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
    },
        \\[foo](bar)
    );
}

// TODO: add heading shift
// (currently mitchellkember.com uses h2 for post title, and h1 within!)
pub const Options = struct {
    is_inline: bool = false,
    first_block_only: bool = false,
};

fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();
        const max_depth = 8;
        items: std.BoundedArray(T, max_depth) = .{},
        footnote: if (T == BlockTag) ?[]const u8 else void = if (T == BlockTag) null else {},

        fn len(self: Self) usize {
            return self.items.len;
        }

        fn get(self: Self, i: usize) T {
            return self.items.get(i);
        }

        fn last(self: Self) ?T {
            return if (self.len() == 0) null else self.items.get(self.len() - 1);
        }

        fn push(self: *Self, writer: anytype, scanner: *Scanner, location: Location, item: T) !void {
            try self.writeOpenTag(writer, item);
            if (T == BlockTag and tagGoesOnItsOwnLine(item)) try writer.writeByte('\n');
            self.items.append(item) catch |err| switch (err) {
                error.Overflow => return scanner.failAt(location, "exceeded maximum depth ({})", .{max_depth}),
            };
        }

        fn writeOpenTag(self: Self, writer: anytype, item: T) !void {
            if (T == BlockTag) if (self.footnote) |number| switch (item) {
                .ol => return writer.writeAll("<hr>\n<ol class=\"footnotes\">"),
                .li => return std.fmt.format(writer, "<li id=\"fn:{s}\">", .{number}),
                else => {},
            };
            try std.fmt.format(writer, "<{s}>", .{@tagName(item)});
        }

        fn pop(self: *Self, writer: anytype) !void {
            var item = self.items.pop();
            if (T == BlockTag and item == .li) if (self.footnote) |number|
                try std.fmt.format(writer, "&nbsp;<a href=\"#fnref:{s}\">↩︎</a>", .{number});
            if (T == BlockTag and item == .ol) self.footnote = null;
            if (T == BlockTag and tagGoesOnItsOwnLine(item)) try writer.writeByte('\n');
            try std.fmt.format(writer, "</{s}>", .{@tagName(item)});
        }

        fn truncate(self: *Self, writer: anytype, new_len: usize) !void {
            while (self.items.len > new_len) try self.pop(writer);
        }

        fn pushOrPop(self: *Self, writer: anytype, scanner: *Scanner, location: Location, item: T) !void {
            try if (self.last() == item) self.pop(writer) else self.push(writer, scanner, location, item);
        }
    };
}

const BlockTag = enum { p, li, h1, h2, h3, h4, h5, h6, ol, ul, blockquote };
const InlineTag = enum { em, strong, code, a };

fn tagGoesOnItsOwnLine(tag: BlockTag) bool {
    return switch (tag) {
        .ol, .ul, .blockquote => true,
        else => false,
    };
}

fn headingTag(level: u8) BlockTag {
    return @enumFromInt(@intFromEnum(BlockTag.h1) + level - 1);
}

fn implicitChildBlock(parent: ?BlockTag) ?BlockTag {
    return switch (parent orelse return .p) {
        .ol, .ul => .li,
        .blockquote => .p,
        else => null,
    };
}

// TODO reconsider arg order
pub fn render(markdown: Markdown, reporter: *Reporter, writer: anytype, options: Options) !void {
    var scanner = Scanner{
        .source = markdown.body.text,
        .reporter = reporter,
        .filename = markdown.filename,
        .location = markdown.body.location,
    };
    var tokenizer = try Tokenizer.init(&scanner);
    var blocks = Stack(BlockTag){};
    var inlines = Stack(InlineTag){};
    var first_iteration = true;
    outer: while (true) {
        var token = try tokenizer.next(&scanner) orelse break;
        var new_footnote: ?[]const u8 = null;
        var open: usize = 0;
        while (open < blocks.len()) : (open += 1) {
            switch (blocks.get(open)) {
                .p, .li, .h1, .h2, .h3, .h4, .h5, .h6 => break,
                .ul => if (token.value != .@"-") break,
                .ol => if (blocks.footnote) |_| switch (token.value) {
                    .@"[^x]: " => |number| new_footnote = number,
                    else => break,
                } else if (token.value != .@"1.") break,
                .blockquote => if (token.value != .@">") break,
            }
            token = try tokenizer.next(&scanner) orelse break :outer;
        }
        try blocks.truncate(writer, open);
        blocks.footnote = new_footnote;
        if (token.value == .@"\n") continue;
        if (!first_iteration) try writer.writeByte('\n');
        first_iteration = false;
        var need_implicit_block = !options.is_inline;
        while (true) {
            if (need_implicit_block and token.value.is_inline()) {
                if (!(tokenizer.in_raw_html_block and blocks.len() == 0))
                    if (implicitChildBlock(blocks.last())) |block|
                        try blocks.push(writer, &scanner, token.location, block);
                need_implicit_block = false;
            }
            switch (token.value) {
                .@"\n" => break,
                .@"#" => |level| try blocks.push(writer, &scanner, token.location, headingTag(level)),
                .@"-" => try blocks.push(writer, &scanner, token.location, .ul),
                .@"1." => try blocks.push(writer, &scanner, token.location, .ol),
                .@">" => try blocks.push(writer, &scanner, token.location, .blockquote),
                .@"* * *" => try writer.writeAll("<hr>"),
                // TODO: syntax highlighting (incremental)
                // TODO: handle when ``` is both opening and closing
                .@"```x" => |lang| try std.fmt.format(writer, "<pre><code class=\"lang-{s}\">", .{lang}),
                .@"```" => try writer.writeAll("</code></pre>"),
                .@"[^x]: " => |number| {
                    blocks.footnote = number;
                    try blocks.push(writer, &scanner, token.location, .ol);
                },
                .text => |text| try writer.writeAll(text),
                .@"<" => try writer.writeAll("&lt;"),
                .@"&" => try writer.writeAll("&amp;"),
                .escaped => |char| try writer.writeByte(char),
                .@"[^x]" => |number| if (!options.first_block_only)
                    try std.fmt.format(writer,
                        \\<sup id="fnref:{0s}"><a href="#fn:{0s}">{0s}</a></sup>
                    , .{number}),
                ._ => try inlines.pushOrPop(writer, &scanner, token.location, .em),
                .@"**" => try inlines.pushOrPop(writer, &scanner, token.location, .strong),
                .@"`" => try inlines.pushOrPop(writer, &scanner, token.location, .code),
                // TODO hooks for links, to resolve links to other pages, etc.
                .@"[...](x)" => |url| try std.fmt.format(writer, "<a href=\"{s}\">", .{url}),
                .@"[...][x]" => |label| try std.fmt.format(writer, "<a href=\"{s}\">", .{markdown.links.get(label) orelse
                    return scanner.failAt(token.location, "link label '{s}' not defined", .{label})}),
                .@"]" => try writer.writeAll("</a>"),
                // TODO can combine some of these, write @tagName.
                .@"‘" => try writer.writeAll("‘"),
                .@"’" => try writer.writeAll("’"),
                .@"“" => try writer.writeAll("“"),
                .@"”" => try writer.writeAll("”"),
                .@"--" => try writer.writeAll("–"),
                .@" -- " => try writer.writeAll("—"),
                .@"..." => try writer.writeAll("…"),
            }
            token = try tokenizer.next(&scanner) orelse break :outer;
        }
        if (inlines.last()) |tag| return scanner.failAt(token.location, "unclosed <{s}> tag", .{@tagName(tag)});
        if (options.first_block_only) break;
    }
    if (inlines.last()) |tag| return scanner.fail("unclosed <{s}> tag", .{@tagName(tag)});
    try blocks.truncate(writer, 0);
}

fn expectRenderSuccess(expected_html: []const u8, source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const markdown = try parse(allocator, &scanner);
    var actual_html = std.ArrayList(u8).init(allocator);
    try markdown.render(&reporter, actual_html.writer(), options);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectRenderFailure(expected_message: []const u8, source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const markdown = try parse(allocator, &scanner);
    try reporter.expectFailure(expected_message, markdown.render(&reporter, std.io.null_writer, options));
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
    try expectRenderSuccess("<p><a href=\"//example.com\">foo</a></p>", "[foo](//example.com)", .{});
}

test "render reference link" {
    try expectRenderSuccess(
        \\<p>Look at <a href="//example.com">foo</a>.</p>
    ,
        \\Look at [foo][bar].
        \\
        \\[bar]: //example.com
    , .{});
}

test "render shortcut reference link" {
    try expectRenderSuccess(
        \\<p>Look at <a href="//example.com">foo</a>.</p>
    ,
        \\Look at [foo].
        \\
        \\[foo]: //example.com
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
    ,
        \\# This is h1
        \\## This is h2
        \\### This is h3
        \\#### This is h4
        \\##### This is h5
        \\###### This is h6
    , .{});
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
