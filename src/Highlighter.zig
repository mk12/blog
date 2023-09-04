// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements basic code highlighting, targeting HTML and CSS.
//! When the language is null, it still does some work to escape "<" and "&".
//! It is driven one line at a time so that it can be used by the Markdown
//! renderer (where code blocks can be nested in blockquotes, for example).

const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const assert = std.debug.assert;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Highlighter = @This();

active: bool = false,
language: ?Language = null,
class: ?u8 = null,
pending_newlines: u32 = 0,

pub const Language = enum {
    c,
    ruby,
    scheme,

    pub fn from(str: []const u8) ?Language {
        return std.meta.stringToEnum(Language, str);
    }
};

const Token = enum {
    // Special cases
    @"<",
    @"&",
    whitespace,

    // Classes
    keyword,
    comment,
    constant,
    string,

    fn class(self: Token) u8 {
        return switch (self) {
            .keyword => 'K',
            .comment => 'C',
            .constant => 'N',
            .string => 'S',
            else => unreachable,
        };
    }
};

fn isKeyword(comptime language: Language, identifier: []const u8) bool {
    const keywords = switch (language) {
        .c => .{
            "char",
            "int",
            "void",
        },
        .ruby => .{
            "def",
            "end",
            "test",
        },
        .scheme => .{
            "define",
        },
    };
    comptime var kv_list: []const struct { []const u8 } = &.{};
    inline for (keywords) |keyword| kv_list = kv_list ++ .{.{keyword}};
    return std.ComptimeStringMap(void, kv_list).has(identifier);
}

pub fn begin(self: *Highlighter, writer: anytype, language: ?Language) !void {
    try writer.writeAll("<pre>\n<code>");
    self.active = true;
    self.language = language;
}

pub fn end(self: *Highlighter, writer: anytype) !void {
    try self.flush(writer);
    try writer.writeAll("</code>\n</pre>");
    self.active = false;
}

pub fn renderLine(self: *Highlighter, writer: anytype, scanner: *Scanner) !void {
    _ = scanner;
    _ = writer;
    _ = self;
    // while (true) {
    //     const status = try self.renderPrefix(writer, scanner);
    //     self.pending_to = scanner.offset;
    //     switch (status) {
    //         .wrote => self.pending_from = scanner.offset,
    //         .did_not_write => {},
    //         .end_of_line => break,
    //     }
    // }
}

fn recognize(self: *Highlighter, scanner: *Scanner) ?Token {
    const writer: usize = 0;
    const language = self.language;
    const start = scanner.offset;
    const char = scanner.next() orelse return .end_of_line;
    switch (char) {
        '\n' => return .end_of_line,
        '<' => return self.write(writer, "&lt;", null),
        '&' => return self.write(writer, "&amp;", null),
        '0'...'9' => {
            while (scanner.peek()) |c| switch (c) {
                '0'...'9', '.', '_' => scanner.eat(c),
                else => break,
            };
            return self.write(writer, scanner.source[start..scanner.offset], .cn);
        },
        ' ' => {
            while (scanner.peek()) |c| switch (c) {
                ' ' => scanner.eat(),
                else => break,
            };
            try self.writeWhitespace(scanner.source[start..scanner.offset]);
        },
        '"' => {
            var escape = false;
            while (scanner.next()) |c| {
                if (escape) {
                    escape = false;
                    continue;
                }
                switch (c) {
                    '\\' => escape = true,
                    '"' => break,
                    '&' => unreachable,
                    '<' => unreachable,
                    else => {},
                }
            } else {
                return scanner.fail("unterminated string literal", .{});
            }
            try self.write(writer, scanner.source[start..scanner.offset], .st);
        },
        '\'' => {
            // TODO scheme, don't do this
            var escape = false;
            while (scanner.next()) |c| {
                if (escape) {
                    escape = false;
                    continue;
                }
                switch (c) {
                    '\\' => escape = true,
                    '\'' => break,
                    '&' => return scanner.fail("entity in string not handled", .{}),
                    '<' => return scanner.fail("entity in string not handled", .{}),
                    else => {},
                }
            } else {
                return scanner.fail("unterminated string literal", .{});
            }
            try self.write(writer, scanner.source[start..scanner.offset], switch (language) {
                .ruby => .st,
                .c => .cn,
                // TODO remove
                .scheme => null,
            });
        },
        'a'...'z', 'A'...'Z' => {
            while (scanner.peek()) |c| switch (c) {
                'a'...'z', 'A'...'Z', '_' => scanner.eat(),
                '-' => if (language == .scheme) scanner.eat() else break,
                else => break,
            };
            const text = scanner.source[start..scanner.offset];
            const kw = switch (language) {
                inline else => |lang| isKeyword(lang, text),
            };
            try self.write(writer, text, if (kw) .kw else null);
        },
        '/' => {
            if (language == .c and scanner.peek() == '/') {
                while (scanner.peek()) |c| switch (c) {
                    '\n' => break,
                    else => scanner.eat(),
                };
                try self.write(writer, scanner.source[start..scanner.offset], .co);
            } else {
                // TODO remove
                try self.write(writer, scanner.source[start..scanner.offset], null);
            }
        },
        '#' => {
            if (language == .ruby) {
                scanner.offset -= 1;
                try self.write(writer, scanner.consumeUntilEol(), .co);
                return .end_of_line;
            } else {
                // TODO remove
                try self.write(writer, scanner.source[start..scanner.offset], null);
            }
        },
        else => return .did_not_write,
        // TODO handle @, : in ruby
        // '(', ')', ',', '*', '.', '-', '+', '=', ':', ';', '{', '}', '[', ']', '@', '?' => try self.write(writer, scanner.source[start..scanner.offset], null),
        // else => return scanner.fail("highlighter encountered unexpected character: '{c}'", .{char}),
    }
}

// fn write(self: *Highlighter, writer: anytype, text: []const u8, class: ?Class) !Status {
//     if (class == self.class and self.pending_is_space) {
//         try self.flushPending(writer);
//     } else {
//         try self.flush(writer);
//         if (class) |c| try fmt.format(writer, "<span class=\"{s}\">", .{@tagName(c)});
//         self.class = class;
//     }
//     try writer.writeAll(text);
//     return .wrote;
// }

fn writeWhitespace(self: *Highlighter, writer: anytype, text: []const u8) !void {
    _ = text;
    _ = writer;
    _ = self;
}

fn flush(self: *Highlighter, writer: anytype) !void {
    try self.flushSpanTag(writer);
    try self.flushPending(writer);
}

fn flushSpanTag(self: *Highlighter, writer: anytype) !void {
    if (self.class) |_| {
        try writer.writeAll("</span>");
        self.class = null;
    }
}

fn flushPending(self: *Highlighter, writer: anytype) !void {
    if (self.pending) |text| {
        try writer.writeAll(text);
        self.pending = null;
    }
}

fn expectHighlight(expected_html: []const u8, source: []const u8, language: ?Language) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_html = std.ArrayList(u8).init(allocator);
    const writer = actual_html.writer();
    var highlighter = Highlighter{};
    try highlighter.begin(writer, language);
    while (!scanner.eof()) try highlighter.renderLine(writer, &scanner);
    try highlighter.end(writer);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

test "empty" {
    try expectHighlight("<pre>\n<code></code>\n</pre>", "", null);
}

test "one line" {
    try expectHighlight("<pre>\n<code>Foo</code>\n</pre>", "Foo", null);
}

test "escape with entities" {
    try expectHighlight("<pre>\n<code>&lt;&amp;></code>\n</pre>", "<&>", null);
}

test "two keywords in a row" {
    try expectHighlight("<pre>\n<code><span class=\"kw\">def def</span></code>\n</pre>", "def def", .ruby);
}

test "two keywords on separate lines" {
    try expectHighlight("<pre>\n<code><span class=\"kw\">def\ndef</span></code>\n</pre>", "def\ndef", .ruby);
}

test "two keywords on separate lines with indent" {
    try expectHighlight("<pre>\n<code><span class=\"kw\">def\n  def</span></code>\n</pre>", "def\n  def", .ruby);
}

test "two keywords on separate lines with blank" {
    try expectHighlight("<pre>\n<code><span class=\"kw\">def\n\ndef</span></code>\n</pre>", "def\n\ndef", .ruby);
}

test "highlight ruby" {
    try expectHighlight(
        \\<pre>
        \\<code><span class="co"># Comment</span>
        \\<span class="kw">def</span> hello()
        \\  print(<span class="st">"hi"</span>, <span class="cn">123</span>)
        \\<span class="kw">end</span></code>
        \\</pre>
    ,
        \\# Comment
        \\def hello()
        \\  print("hi", 123)
        \\end
    , .ruby);
}
