// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;

pub const Document = struct { body: Span, links: LinkMap };
pub const LinkMap = std.StringHashMapUnmanaged([]const u8);

pub fn parseLinkDefinitions(allocator: Allocator, scanner: *Scanner) !Document {
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
    return Document{ .body = body, .links = links };
}

test "parseLinkDefinitions" {
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
    const doc = try parseLinkDefinitions(allocator, &scanner);
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

test "parseLinkDefinitions with gaps" {
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
    const doc = try parseLinkDefinitions(allocator, &scanner);
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
    // block_html: []const u8,
    @"#": u8,
    @"-",
    @"1.",
    @">",
    @"* * *",
    // @"```x": []const u8,
    // @"```",
    // @"$$",
    // @"[^x]: ": []const u8,
    // TODO: figures, tables, ::: verse

    // Inline tokens
    text: []const u8,
    // inline_html: []const u8,
    @"`x`": []const u8,
    // @"$",
    // @"[^x]": []const u8,
    // TODO(https://github.com/ziglang/zig/issues/16714): Change to @"_".
    emph,
    @"**",
    // @"[",
    // @"](x)": []const u8,
    // @"][x]": []const u8,
    // @"'",
    // @"\"",
    @" -- ",
    // @"...",

    fn is_inline(self: TokenValue) bool {
        return @intFromEnum(self) >= @intFromEnum(TokenValue.text);
    }
};

const Tokenizer = struct {
    peeked: ?Token = null,
    block_allowed: bool = true,

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
            const char = scanner.next() orelse return null;
            if (self.block_allowed) {
                switch (char) {
                    '#' => {
                        var level: u8 = 1;
                        while (scanner.peek(0)) |c| switch (c) {
                            '#' => {
                                _ = scanner.next();
                                level += 1;
                            },
                            ' ' => {
                                _ = scanner.next();
                                break :blk .{ .@"#" = level };
                            },
                            else => break,
                        };
                    },
                    '>' => {
                        while (scanner.peek(0)) |c| if (c == ' ') scanner.eat(c) else break;
                        break :blk .@">";
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
                    '*' => if (scanner.attempt(" * *") and scanner.peek(0) == '\n') {
                        break :blk .@"* * *";
                    },
                    else => {},
                }
            }
            self.block_allowed = false;
            switch (char) {
                '\n' => {
                    while (scanner.peek(0)) |c| if (c == '\n') scanner.eat(c) else break;
                    break :blk .@"\n";
                },
                '`' => {
                    const span = try scanner.until('`');
                    break :blk .{ .@"`x`" = span.text };
                },
                '*' => if (scanner.peek(0) == '*') {
                    _ = scanner.next();
                    break :blk .@"**";
                },
                '_' => break :blk .emph,
                ' ' => if (scanner.attempt("-- ")) break :blk .@" -- ",
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
    // try expectTokens(&[_]TokenValue{
    //     .underscore,
    //     .{ .text = "Hello" },
    //     .underscore,
    //     .{ .text = " " },
    //     .@"**",
    //     .{ .text = "world" },
    //     .@"**",
    //     .{ .text = "!" },
    // },
    //     \\_Hello_ **world**!
    // );
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
            try std.fmt.format(writer, "<{s}>", .{@tagName(item)});
            if (T == BlockTag and tagGoesOnItsOwnLine(item)) try writer.writeByte('\n');
            self.items.append(item) catch |err| switch (err) {
                error.Overflow => return scanner.failAt(location, "exceeded maximum depth ({})", .{max_depth}),
            };
        }

        fn pop(self: *Self, writer: anytype) !void {
            const item = self.items.pop();
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
const InlineTag = enum { em, strong, a };

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

pub fn render(scanner: *Scanner, writer: anytype, links: LinkMap, options: Options) !void {
    _ = links;
    var blocks = Stack(BlockTag){};
    var inlines = Stack(InlineTag){};
    var tokenizer = try Tokenizer.init(scanner);
    var first_iteration = true;
    outer: while (true) {
        var token = try tokenizer.next(scanner) orelse break;
        if (!options.is_inline) {
            var open: usize = 0;
            while (open < blocks.len()) : (open += 1) {
                switch (blocks.get(open)) {
                    .p, .li, .h1, .h2, .h3, .h4, .h5, .h6 => break,
                    .ul => if (token.value != .@"-") break,
                    .ol => if (token.value != .@"1.") break,
                    .blockquote => if (token.value != .@">") break,
                }
                token = try tokenizer.next(scanner) orelse break :outer;
            }
            try blocks.truncate(writer, open);
            if (!first_iteration) try writer.writeByte('\n');
            first_iteration = false;
        }
        var need_implicit_block = !options.is_inline;
        while (true) {
            if (need_implicit_block and token.value.is_inline()) {
                if (implicitChildBlock(blocks.last())) |block|
                    try blocks.push(writer, scanner, token.location, block);
                need_implicit_block = false;
            }
            switch (token.value) {
                .@"\n" => break,
                .@"#" => |level| try blocks.push(writer, scanner, token.location, headingTag(level)),
                .@"-" => try blocks.push(writer, scanner, token.location, .ul),
                .@"1." => try blocks.push(writer, scanner, token.location, .ol),
                .@">" => try blocks.push(writer, scanner, token.location, .blockquote),
                .@"* * *" => try writer.writeAll("<hr>"),
                // TODO: escape < > &
                .text => |text| try writer.writeAll(text),
                .@"`x`" => |code| try std.fmt.format(writer, "<code>{s}</code>", .{code}),
                .emph => try inlines.pushOrPop(writer, scanner, token.location, .em),
                .@"**" => try inlines.pushOrPop(writer, scanner, token.location, .strong),
                .@" -- " => try writer.writeAll("—"),
            }
            token = try tokenizer.next(scanner) orelse break :outer;
        }
        try inlines.truncate(writer, 0);
        if (options.first_block_only) break;
    }
    try inlines.truncate(writer, 0);
    try blocks.truncate(writer, 0);
}

fn expectRenderSuccess(expected_html: []const u8, source: []const u8, links: LinkMap, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_html = std.ArrayList(u8).init(allocator);
    try render(&scanner, actual_html.writer(), links, options);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectRenderFailure(expected_message: []const u8, source: []const u8, links: LinkMap, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, render(&scanner, std.io.null_writer, links, options));
}

test "render empty string" {
    try expectRenderSuccess("", "", .{}, .{});
    try expectRenderSuccess("", "", .{}, .{ .is_inline = true });
    try expectRenderSuccess("", "", .{}, .{ .first_block_only = true });
    try expectRenderSuccess("", "", .{}, .{ .is_inline = true, .first_block_only = true });
}

test "render text" {
    try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{}, .{});
    try expectRenderSuccess("Hello world!", "Hello world!", .{}, .{ .is_inline = true });
    try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{}, .{ .first_block_only = true });
    try expectRenderSuccess("Hello world!", "Hello world!", .{}, .{ .is_inline = true, .first_block_only = true });
}

test "render first block only" {
    const source =
        \\This is the first paragraph.
        \\
        \\This is the second paragraph.
    ;
    try expectRenderSuccess("<p>This is the first paragraph.</p>", source, .{}, .{ .first_block_only = true });
    try expectRenderSuccess("This is the first paragraph.", source, .{}, .{ .is_inline = true, .first_block_only = true });
}

test "render first block only with gap" {
    const source =
        \\
        \\This is the first paragraph.
        \\
        \\This is the second paragraph.
    ;
    try expectRenderSuccess("<p>This is the first paragraph.</p>", source, .{}, .{ .first_block_only = true });
    try expectRenderSuccess("This is the first paragraph.", source, .{}, .{ .is_inline = true, .first_block_only = true });
}

test "render code" {
    try expectRenderSuccess("<p><code>foo_bar</code></p>", "`foo_bar`", .{}, .{});
}

test "render emphasis" {
    try expectRenderSuccess("<p>Hello <em>world</em>!</p>", "Hello _world_!", .{}, .{});
}

test "render strong" {
    try expectRenderSuccess("<p>Hello <strong>world</strong>!</p>", "Hello **world**!", .{}, .{});
}

test "render nested inlines" {
    try expectRenderSuccess(
        \\<p>a <strong>b <em>c <code>d</code> e</em> f</strong> g</p>
    ,
        \\a **b _c `d` e_ f** g
    , .{}, .{});
}

test "render heading" {
    try expectRenderSuccess("<h1>This is h1</h1>", "# This is h1", .{}, .{});
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
    , .{}, .{});
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
    , .{}, .{});
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
    , .{}, .{});
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
    , .{}, .{});
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
    , .{}, .{});
}

// TODO: eliminate extra blank lines
test "render nested blockquotes" {
    try expectRenderSuccess(
        \\<p>Quote:</p>
        \\<blockquote>
        \\<p>Some stuff.</p>
        \\
        \\<ul>
        \\<li>For example.</li>
        \\</ul>
        \\
        \\<blockquote>
        \\<blockquote>
        \\<p>Deep!</p>
        \\</blockquote>
        \\
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
    , .{}, .{});
}

test "render smart typography" {
    try expectRenderSuccess(
        \\<p>This—that.</p>
    ,
        \\This -- that.
    , .{}, .{});
}

// TODO: test render failures
