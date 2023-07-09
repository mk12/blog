// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;

pub const LinkMap = std.StringHashMapUnmanaged([]const u8);

pub fn parseLinkDefinitions(allocator: Allocator, scanner: *Scanner) !struct { body: Span, links: LinkMap } {
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
    const body = Span{
        .text = source,
        .location = scanner.location,
    };
    return .{ .body = body, .links = links };
}

test "parseLinkDefinitions" {
    const source =
        \\This is the content.
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
    const result = try parseLinkDefinitions(allocator, &scanner);
    try testing.expectEqualStrings(
        \\This is the content.
        \\
        \\[This is not a link]
    , result.body.text);
    try testing.expectEqualDeep(Location{}, result.body.location);
    try testing.expectEqual(@as(usize, 2), result.links.size);
    try testing.expectEqualStrings("foo link", result.links.get("foo").?);
    try testing.expectEqualStrings("bar baz link", result.links.get("bar baz").?);
}

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
    @"#": usize,
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
    // try expectTokens(&[_]TokenValue{}, "");
}

test "tokenize text" {
    // try expectTokens(&[_]TokenValue{.{ .text = "Hello world!" }}, "Hello world!");
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

pub fn render(scanner: *Scanner, writer: anytype, links: LinkMap, options: Options) !void {
    _ = links;
    _ = options.is_inline;
    _ = options.first_paragraph_only;
    var tokenizer = Tokenizer{};
    try helper(scanner, &tokenizer, writer);
}

fn helper(
    scanner: *Scanner,
    tokenizer: *Tokenizer,
    writer: anytype,
    links: LinkMap,
) !void {
    _ = links;
    const token = (try tokenizer.next(scanner)).?;
    switch (token.value) {
        .text => |text| try writer.writeAll(text),
        .code => |code| try std.fmt.format(writer, "<code>{s}</code>", .{code}),
        // TODO: syntax highlighting
        .code_block => |code_block| try std.fmt.format(
            writer,
            "<pre><code class=\"lang-{s}\">{s}</code></pre>",
            .{ code_block.language, code_block.code },
        ),
        // TODO: MathML
        .inline_math => try writer.writeAll("(inline math)"),
        .display_math => try writer.writeAll("(display math)"),
        // Block markers
        .new_paragraph => {},
        // TODO: Wrong, need to just do open tag, and recurse to close it later
        .@"#" => try std.fmt.format(writer, "<h{0d}></h{0d}>", .{}),
        .@">" => {},
        .@"-" => {},
        .@"1." => {},
        .@"* * *" => {},
        // Inline markers
        .underscore => {},
        .@"**" => {},
        // Typography
        // TODO: smart quotes
        .@"'" => try writer.writeAll("'"),
        .@"\"" => try writer.writeAll("\""),
        .@"--" => try writer.writeAll("—"),
        .@"..." => try writer.writeAll("…"),
        // Links
        // =====================================================================
        // TODO!!! Cannot render in single pass, need link URLs.
        // perhaps 1st quick pass to find link definitions.
        // Maybe part of Post parsing?
        // =====================================================================
        .@"[" => {},
        .@"](?)" => {},
        .@"][?]" => {},
        // Footnotes
        .@"[^?]" => |label| try std.fmt.format(writer, "<sup><a href=\"#fn-{0s}\">{0s}</a></sup>", .{label}),
        // Definitions
        .@"[?]: ?" => return scanner.failAt(token.location, "unexpected link definition", .{}),
        // Images
        .@"![?](?)" => try writer.writeAll("(image)"),
        // Tables
        .@"|" => try writer.writeAll("(table)"),
        .@"|:-:" => try writer.writeAll("(table)"),
        .end_of_tr => try writer.writeAll("(table)"),
    }
}

// fn descend(self: Markdown, reporter: *Reporter, writer: anytype, comptime tag: []const u8) !void {
//     _ = reporter;
//     _ = self;
//     try writer.writeAll("<" ++ tag ++ ">");
//     try writer.writeAll("</" ++ tag ++ ">");
// }

fn expectRenderSuccess(expected_html: []const u8, source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_html = std.ArrayList(u8).init(allocator);
    try render(&scanner, actual_html.writer(), options);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectRenderFailure(expected_message: []const u8, source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reporter = Reporter.init(arena.allocator());
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, render(&scanner, std.io.null_writer, options));
}

// test "render empty string" {
//     try expectRenderSuccess("", "", .{});
//     try expectRenderSuccess("", "", .{ .is_inline = true });
// }

// test "render text" {
//     try expectRenderSuccess("<p>Hello world!</p>", "Hello world!", .{});
//     try expectRenderSuccess("Hello world!", "Hello world!", .{ .is_inline = true });
// }
