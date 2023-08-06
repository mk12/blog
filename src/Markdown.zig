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
    outer: while (std.mem.lastIndexOfScalar(u8, source, '\n')) |newline_index| {
        var i = newline_index + 1;
        if (i == source.len or source[i] != '[') break;
        i += 1;
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

const Token = struct {
    value: TokenValue,
    location: Location,
};

const TokenValue = union(enum) {
    // Blocks tokens
    newline,
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
    // @"`",
    // @"$",
    // @"[^x]": []const u8,
    // @"_",
    @"**",
    // @"[",
    // @"](x)": []const u8,
    // @"][x]": []const u8,
    // @"'",
    // @"\"",
    // @" -- ",
    // @"...",

    fn is_inline(self: TokenValue) bool {
        return switch (self) {
            .text => true,
            else => false,
        };
    }
};

const Tokenizer = struct {
    buffer: std.BoundedArray(Token, 2) = .{},
    block_allowed: bool = true,

    fn peek(self: *Tokenizer, scanner: *Scanner) !?Token {
        const len = self.buffer.len;
        if (len > 0) return self.buffer.get(len - 1);
        const token = try self.next(scanner) orelse return null;
        self.buffer.appendAssumeCapacity(token);
        return token;
    }

    fn next(self: *Tokenizer, scanner: *Scanner) !?Token {
        if (self.buffer.popOrNull()) |token| return token;
        const start_offset = scanner.offset;
        const start_location = scanner.location;
        const result = try self.nextNonText(scanner);
        const end_offset = if (result) |res| res.offset else scanner.offset;
        if (start_offset == end_offset)
            return if (result) |res| Token{ .value = res.value, .location = res.location } else null;
        if (result) |res| self.buffer.appendAssumeCapacity(Token{ .value = res.value, .location = res.location });
        return Token{
            .value = .{ .text = scanner.source[start_offset..end_offset] },
            .location = start_location,
        };
    }

    fn nextNonText(self: *Tokenizer, scanner: *Scanner) !?struct {
        value: TokenValue,
        location: Location,
        offset: u32,
    } {
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

pub const Options = struct {
    is_inline: bool = false,
    first_paragraph_only: bool = false,
};

// TODO: thinner abstraction, just top-level push/pop functions?
const BlockStack = struct {
    const Tag = enum { p, li, h1, h2, h3, h4, h5, h6, ol, ul, blockquote };
    const max_depth = 8;
    tags: std.BoundedArray(Tag, max_depth) = .{},
    leaf: Tag, // p, li, or h#
    // except li not a leaf if nested
    check_idx: usize = 0,

    fn headingTag(level: u8) Tag {
        return @enumFromInt(@intFromEnum(Tag.h1) + level - 1);
    }

    fn len(self: BlockStack) usize {
        return self.tags.len;
    }

    fn get(self: BlockStack, i: usize) Tag {
        return self.tags.get(i);
    }

    fn push(self: *BlockStack, tag: Tag, scanner: *Scanner, location: Location, writer: anytype) !void {
        try std.fmt.format(writer, "<{s}>", .{@tagName(tag)});
        self.tags.append(tag) catch |err| switch (err) {
            error.Overflow => return scanner.failAt(location, "exceeded maximum block depth ({})", .{max_depth}),
        };
    }

    fn pop(self: *BlockStack, writer: anytype) !void {
        try std.fmt.format(writer, "</{s}>", .{@tagName(self.tags.pop())});
    }

    fn truncate(self: *BlockStack, i: usize, writer: anytype) !void {
        while (self.len() > i) try self.pop(writer);
    }

    fn newline(self: *BlockStack) void {
        self.check_idx = 0;
    }

    fn openParaOrLi(self: *BlockStack, value: TokenValue, writer: anytype) !void {
        _ = writer;
        _ = self;
        if (value.is_inline()) {
            // if (self.len() == 0) return self.push(.p, scanner,)
        }
    }

    fn maybeConsume(self: *BlockStack, value: TokenValue, writer: anytype) !bool {
        if (self.check_idx == self.len()) {
            try self.openParaOrLi(value, writer);
            return false;
        }
        switch (self.get(self.check_idx)) {
            .p, .li, .h1, .h2, .h3, .h4, .h5, .h6 => try self.openParaOrLi(value, writer),
            .ul, .ol, .blockquote => |tag| {
                const marker = switch (tag) {
                    .ul => TokenValue.@"-",
                    .ol => TokenValue.@"1.",
                    .blockquote => TokenValue.@">",
                    else => unreachable,
                };
                if (value == marker) {
                    self.check_idx += 1;
                    return true;
                }
            },
        }
        try self.truncate(self.check_idx, writer);
        return false;
    }

    fn closeAll(self: *BlockStack, writer: anytype) !void {
        _ = writer;
        _ = self;
        // try blocks.truncate(0, writer);
    }
};

pub fn oldRender(scanner: *Scanner, writer: anytype, links: LinkMap, options: Options) !void {
    _ = links;
    _ = options.is_inline;
    _ = options.first_paragraph_only;
    var tokenizer = Tokenizer{};
    var blocks = BlockStack{};
    while (try tokenizer.next(scanner)) |token| {
        if (try blocks.maybeConsume(token.value, writer)) continue;
        switch (token.value) {
            .newline => blocks.newline(),
            .@"#" => |level| try blocks.push(BlockStack.headingTag(level), scanner, token.location, writer),
            .@"* * *" => try writer.writeAll("<hr>"),
            .@">" => try blocks.push(.blockquote, scanner, token.location, writer),
        }
    }
    try blocks.closeAll();

    // > Hi
    // >
    // > ```
    // > nice
    // > ```
    //
}

// problem: <a href="..." but don't see URL till end.
// probably have to do two full passes
// or write into buffer then copy

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
            self.items.append(item) catch |err| switch (err) {
                error.Overflow => return scanner.failAt(location, "exceeded maximum depth ({})", .{max_depth}),
            };
        }

        fn pop(self: *Self, writer: anytype) !void {
            try std.fmt.format(writer, "</{s}>", .{@tagName(self.items.pop())});
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

fn headingTag(level: u8) BlockTag {
    return @enumFromInt(@intFromEnum(BlockTag.h1) + level - 1);
}

pub fn render(scanner: *Scanner, writer: anytype, links: LinkMap, options: Options) !void {
    _ = links;
    var blocks = Stack(BlockTag){};
    var inlines = Stack(InlineTag){};
    var tokenizer = Tokenizer{};
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
            const last = blocks.last();
            try blocks.push(writer, scanner, token.location, if (last == .ol or last == .ul) .li else .p);
        }
        while (true) {
            switch (token.value) {
                .newline => break,
                .@"#" => |level| try blocks.push(writer, scanner, token.location, headingTag(level)),
                .@"-" => try blocks.push(writer, scanner, token.location, .ul),
                .@"1." => try blocks.push(writer, scanner, token.location, .ol),
                .@">" => try blocks.push(writer, scanner, token.location, .blockquote),
                .@"* * *" => try writer.writeAll("<hr>"),
                .text => |text| try writer.writeAll(text),
                .@"**" => try inlines.pushOrPop(writer, scanner, token.location, .strong),
            }
            token = try tokenizer.next(scanner) orelse break :outer;
        }
    }
    // close all inlines
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
}

test "render text" {
    try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{}, .{});
    try expectRenderSuccess("Hello world!", "Hello world!", .{}, .{ .is_inline = true });
}
