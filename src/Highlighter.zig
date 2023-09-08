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
mode: ?Mode = null,
class: ?Class = null,
pending_newlines: usize = 0,
pending_spaces: ?[]const u8 = null,

pub const Language = enum {
    c,
    ruby,
    scheme,

    pub fn from(name: []const u8) ?Language {
        return std.meta.stringToEnum(Language, name);
    }
};

const Mode = union(enum) {
    in_string: u8,
    in_line_comment,

    fn class(self: Mode) Class {
        return switch (self) {
            .in_string => .constant,
            .in_line_comment => .comment,
        };
    }
};

const Class = enum {
    keyword,
    constant,
    comment,
    special, // TODO rename
    quite_special, // TODO rename

    fn cssClassName(self: Class) []const u8 {
        return switch (self) {
            .keyword => "kw",
            .constant => "cn",
            .comment => "co",
            .special => "sp",
            .quite_special => "qs",
        };
    }
};

fn isKeyword(comptime language: Language, identifier: []const u8) bool {
    const keywords = switch (language) {
        .c => .{
            "char",
            "for",
            "int",
            "return",
            "void",
        },
        .ruby => .{
            "class",
            "def",
            "do",
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

const Token = union(enum) {
    eol,
    spaces,
    class: Class,
    @"<": ?Class,
    @"&": ?Class,
};

pub fn begin(self: *Highlighter, writer: anytype, language: ?Language) !void {
    try writer.writeAll("<pre>\n<code>");
    self.* = Highlighter{ .active = true, .language = language };
}

pub fn end(self: *Highlighter, writer: anytype) !void {
    self.pending_newlines -|= 1;
    try self.flushCloseSpan(writer);
    try self.flushWhitespace(writer);
    try writer.writeAll("</code>\n</pre>");
    self.* = Highlighter{};
}

pub fn line(self: *Highlighter, writer: anytype, scanner: *Scanner) !void {
    while (true) {
        const start = scanner.offset;
        const token = while (true) {
            const offset = scanner.offset;
            if (self.recognize(scanner)) |token| break .{ .offset = offset, .value = token };
        };
        const normal_text = scanner.source[start..token.offset];
        const token_text = scanner.source[token.offset..scanner.offset];
        if (normal_text.len > 0) try self.write(writer, normal_text, null);
        switch (token.value) {
            .eol => break,
            .spaces => self.pending_spaces = token_text,
            .class => |class| try self.write(writer, token_text, class),
            .@"<" => |class| try self.write(writer, "&lt;", class),
            .@"&" => |class| try self.write(writer, "&amp;", class),
        }
    }
    if (self.pending_spaces) |spaces| return scanner.failOn(spaces, "trailing whitespace", .{});
    self.pending_newlines += 1;
}

fn write(self: *Highlighter, writer: anytype, text: []const u8, class: ?Class) !void {
    if (class == self.class) {
        try self.flushWhitespace(writer);
    } else {
        try self.flushCloseSpan(writer);
        try self.flushWhitespace(writer);
        if (class) |c| try fmt.format(writer, "<span class=\"{s}\">", .{c.cssClassName()});
        self.class = class;
    }
    try writer.writeAll(text);
}

fn flushCloseSpan(self: *Highlighter, writer: anytype) !void {
    if (self.class) |_| {
        try writer.writeAll("</span>");
        self.class = null;
    }
}

fn flushWhitespace(self: *Highlighter, writer: anytype) !void {
    while (self.pending_newlines > 0) : (self.pending_newlines -= 1)
        try writer.writeByte('\n');
    if (self.pending_spaces) |spaces| {
        try writer.writeAll(spaces);
        self.pending_spaces = null;
    }
}

fn recognize(self: *Highlighter, scanner: *Scanner) ?Token {
    if (scanner.eof()) return .eol;
    if (scanner.consumeAny("\n<&")) |char| switch (char) {
        '\n' => return .eol,
        '<' => return .{ .@"<" = if (self.mode) |m| m.class() else null },
        '&' => return .{ .@"&" = if (self.mode) |m| m.class() else null },
        else => unreachable,
    };
    if (scanner.consumeMany(' ') > 0) return .spaces;
    const language = self.language orelse {
        scanner.eat();
        return null;
    };
    const mode = self.mode orelse switch (dispatch(scanner, language)) {
        .none => return null,
        .class => |c| return .{ .class = c },
        .mode => |m| m,
    };
    const finished = switch (mode) {
        .in_string => |delimiter| finishString(scanner, delimiter),
        .in_line_comment => finishLine(scanner),
    };
    if (!finished) self.mode = mode;
    return .{ .class = mode.class() };
}

fn dispatch(scanner: *Scanner, language: Language) union(enum) { none, class: Class, mode: Mode } {
    const start = scanner.offset;
    switch (scanner.next().?) {
        '\n', '<', '&' => unreachable,
        '0'...'9' => {
            while (scanner.peek()) |c| switch (c) {
                '0'...'9', '.', '_' => scanner.eat(),
                else => break,
            };
            return .{ .class = .constant };
        },
        'a'...'z', 'A'...'Z' => {
            while (scanner.peek()) |c| switch (c) {
                'a'...'z', 'A'...'Z', '_' => scanner.eat(),
                '-' => if (language == .scheme) scanner.eat() else break,
                else => break,
            };
            const identifier = scanner.source[start..scanner.offset];
            const is_keyword = switch (language) {
                inline else => |lang| isKeyword(lang, identifier),
            };
            if (is_keyword) return .{ .class = .keyword };
            // TODO only certain languages... or merge into keyword table?
            if (std.mem.eql(u8, identifier, "true") or std.mem.eql(u8, identifier, "false"))
                return .{ .class = .constant };
            // if (language == .ruby and scanner.consume(':'))
            //     return .{ .class = .quite_special };
        },
        '\'' => return .{ .mode = .{ .in_string = '\'' } },
        '"' => return .{ .mode = .{ .in_string = '"' } },
        '#' => switch (language) {
            .ruby => return .{ .mode = .in_line_comment },
            else => {},
        },
        '/' => if (language == .c and scanner.consume('/')) {
            return .{ .mode = .in_line_comment };
        },
        ':' => if (language == .ruby and scanIdentifier(scanner) != null)
            return .{ .class = .quite_special },
        '@' => if (language == .ruby and scanIdentifier(scanner) != null)
            return .{ .class = .special },
        else => {},
    }
    return .none;
}

fn scanIdentifier(scanner: *Scanner) ?[]const u8 {
    const start = scanner.offset;
    while (scanner.peek()) |c| switch (c) {
        'a'...'z', 'A'...'Z', '_' => scanner.eat(),
        else => break,
    };
    const text = scanner.source[start..scanner.offset];
    return if (text.len == 0) null else text;
}

fn finishString(scanner: *Scanner, delimiter: u8) bool {
    var escape = false;
    while (scanner.peek()) |char| {
        if (char == '\n') break;
        scanner.eat();
        if (escape) {
            escape = false;
            continue;
        }
        switch (char) {
            '\\' => escape = true,
            '<', '&' => break scanner.uneat(),
            else => if (char == delimiter) return true,
        }
    }
    return false;
}

fn finishLine(scanner: *Scanner) bool {
    while (scanner.peek()) |char| switch (char) {
        '\n' => break,
        '<', '&' => return false,
        else => scanner.eat(),
    };
    return true;
}

fn expectSuccess(expected_html: []const u8, source: []const u8, language: ?Language) !void {
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
    while (!scanner.eof()) try highlighter.line(writer, &scanner);
    try highlighter.end(writer);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectFailure(expected_message: []const u8, source: []const u8, language: ?Language) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const writer = std.io.null_writer;
    var highlighter = Highlighter{};
    try highlighter.begin(writer, language);
    const result = while (!scanner.eof()) highlighter.line(writer, &scanner) catch |err| break err;
    try highlighter.end(writer);
    try reporter.expectFailure(expected_message, result);
}

test "empty input" {
    try expectSuccess("<pre>\n<code></code>\n</pre>", "", null);
}

test "empty line" {
    try expectSuccess("<pre>\n<code></code>\n</pre>", "\n", null);
}

test "blank line" {
    try expectSuccess("<pre>\n<code>\n</code>\n</pre>", "\n\n", null);
}

test "two blank line" {
    try expectSuccess("<pre>\n<code>\n\n</code>\n</pre>", "\n\n\n", null);
}

test "fails on trailing spaces" {
    try expectFailure("<input>:1:1: \" \": trailing whitespace", " ", null);
}

test "fails on trailing spaces after text" {
    try expectFailure("<input>:2:4: \"   \": trailing whitespace", "\nfoo   \n", null);
}

test "one line" {
    try expectSuccess("<pre>\n<code>Foo</code>\n</pre>", "Foo", null);
}

test "escape with entities" {
    try expectSuccess("<pre>\n<code>&lt;&amp;></code>\n</pre>", "<&>", null);
}

test "two keywords in a row" {
    try expectSuccess("<pre>\n<code><span class=\"kw\">def def</span></code>\n</pre>", "def def", .ruby);
}

test "two keywords on separate lines" {
    try expectSuccess("<pre>\n<code><span class=\"kw\">def\ndef</span></code>\n</pre>", "def\ndef", .ruby);
}

test "two keywords on separate lines with indent" {
    try expectSuccess("<pre>\n<code><span class=\"kw\">def\n  def</span></code>\n</pre>", "def\n  def", .ruby);
}

test "two keywords on separate lines with blank" {
    try expectSuccess("<pre>\n<code><span class=\"kw\">def\n\ndef</span></code>\n</pre>", "def\n\ndef", .ruby);
}

test "highlight ruby" {
    try expectSuccess(
        \\<pre>
        \\<code><span class="co"># Comment</span>
        \\<span class="kw">def</span> hello()
        \\  print(<span class="cn">"hi"</span>, <span class="cn">123</span>)
        \\<span class="kw">end</span></code>
        \\</pre>
    ,
        \\# Comment
        \\def hello()
        \\  print("hi", 123)
        \\end
    , .ruby);
}
