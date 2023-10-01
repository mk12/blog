// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements basic code highlighting, targeting HTML and CSS.
//! When the language is null, it still does some work to escape "<" and "&".
//! It scans input until a closing "```" delimiter, and it yields control when
//! it encounters a newline, so it can be used by the Markdown renderer.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Highlighter = @This();

language: ?Language,
class: ?Class = null,
mode: ?Mode = null,
pending_newlines: usize = 0,
pending_spaces: ?[]const u8 = null,

pub const Language = enum {
    c,
    haskell,
    ruby,
    scheme,

    pub fn from(name: []const u8) ?Language {
        return std.meta.stringToEnum(Language, name);
    }
};

const Class = enum {
    keyword,
    constant,
    comment,
    class_a,
    class_b,

    fn cssClassName(self: Class) []const u8 {
        return switch (self) {
            .keyword => "kw",
            .constant => "cn",
            .comment => "co",
            .class_a => "ca",
            .class_b => "cb",
        };
    }
};

fn classifyIdentifier(comptime language: Language, identifier: []const u8) ?Class {
    const list = switch (language) {
        .c => .{
            // Keywords
            .{ "else", .keyword },
            .{ "for", .keyword },
            .{ "if", .keyword },
            .{ "return", .keyword },
            .{ "sizeof", .keyword },

            // Types
            .{ "char", .class_a },
            .{ "int", .class_a },
            .{ "void", .class_a },

            // Constants
            .{ "false", .constant },
            .{ "true", .constant },
        },
        .haskell => .{
            // Keywords
            .{ "as", .keyword },
            .{ "import", .keyword },
            .{ "otherwise", .keyword },
            .{ "qualified", .keyword },
            .{ "where", .keyword },
        },
        .ruby => .{
            // Keywords
            .{ "class", .keyword },
            .{ "def", .keyword },
            .{ "do", .keyword },
            .{ "end", .keyword },
            .{ "test", .keyword },

            // Constants
            .{ "false", .constant },
            .{ "true", .constant },
        },
        .scheme => .{
            // Special forms
            .{ "and", .keyword },
            .{ "case", .keyword },
            .{ "cond", .keyword },
            .{ "define", .keyword },
            .{ "else", .keyword },
            .{ "if", .keyword },
            .{ "lambda", .keyword },
            .{ "let", .keyword },
            .{ "or", .keyword },

            // Procedures
            .{ "cadr", .class_a },
            .{ "car", .class_a },
            .{ "cddr", .class_a },
            .{ "cdr", .class_a },
            .{ "cons", .class_a },
            .{ "eq?", .class_a },
            .{ "even?", .class_a },
            .{ "list", .class_a },
            .{ "map", .class_a },
            .{ "null?", .class_a },
            .{ "odd?", .class_a },
            .{ "zero?", .class_a },
        },
    };
    return std.ComptimeStringMap(Class, list).get(identifier);
}

const Token = union(enum) {
    eol,
    spaces,
    class: Class,
    @"<": ?Class,
    @"&": ?Class,
};

pub fn render(writer: anytype, language: ?Language) !Highlighter {
    try writer.writeAll("<pre>\n<code>");
    return Highlighter{ .language = language };
}

pub const terminator = "```";

// TODO(https://github.com/ziglang/zig/issues/6025): Use async.
pub fn @"resume"(self: *Highlighter, writer: anytype, scanner: *Scanner) !bool {
    assert(!scanner.eof());
    const finished = scanner.consumeStringEol(terminator);
    try if (finished) self.renderEnd(writer) else self.renderLine(writer, scanner);
    return finished;
}

fn renderEnd(self: *Highlighter, writer: anytype) !void {
    self.pending_newlines -|= 1;
    try self.flushCloseSpan(writer);
    try self.flushWhitespace(writer);
    try writer.writeAll("</code>\n</pre>");
    self.* = undefined;
}

fn renderLine(self: *Highlighter, writer: anytype, scanner: *Scanner) !void {
    while (true) {
        const start = scanner.offset;
        const token, const token_offset = while (true) {
            const offset = scanner.offset;
            if (self.recognize(scanner)) |token| break .{ token, offset };
        };
        const normal_text = scanner.source[start..token_offset];
        const token_text = scanner.source[token_offset..scanner.offset];
        if (normal_text.len > 0) try self.write(writer, normal_text, null);
        switch (token) {
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
        if (class) |c| try writer.print("<span class=\"{s}\">", .{c.cssClassName()});
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
    var mode = self.mode orelse switch (dispatch(scanner, language)) {
        .none => return null,
        .class => |c| return .{ .class = c },
        .mode => |m| m,
    };
    self.mode = if (mode.finish(scanner)) null else mode;
    return if (mode.class()) |c| .{ .class = c } else null;
}

fn dispatch(scanner: *Scanner, language: Language) union(enum) { none, class: Class, mode: Mode } {
    const start = scanner.offset;
    switch (scanner.next().?) {
        '\n', '<', '&' => unreachable,
        '0'...'9' => if (!isWordCharacter(scanner.prev(1))) {
            while (scanner.peek()) |c| switch (c) {
                '0'...'9', '.', '_' => scanner.eat(),
                else => break,
            };
            return .{ .class = .constant };
        },
        'a'...'z', 'A'...'Z' => {
            while (scanner.peek()) |c| : (scanner.eat()) switch (c) {
                'a'...'z', 'A'...'Z', '_' => {},
                '-', '?' => if (language != .scheme) break,
                else => break,
            };
            const identifier = scanRestOfIdentifier(scanner, language, start);
            const class = switch (language) {
                inline else => |lang| classifyIdentifier(lang, identifier),
            };
            if (class) |c| return .{ .class = c };
        },
        '\'' => return switch (language) {
            .scheme => .{ .mode = .{ .scheme_quote = .{} } },
            else => .{ .mode = .{ .string_literal = .{ .delimiter = '\'' } } },
        },
        '"' => return .{ .mode = .{ .string_literal = .{ .delimiter = '"' } } },
        '#' => switch (language) {
            .ruby => return .{ .mode = .line_comment },
            .scheme => if (scanner.consumeAny("tf")) |_| return .{ .class = .constant },
            else => {},
        },
        '/' => if (language == .c and scanner.consume('/')) {
            return .{ .mode = .line_comment };
        },
        ':' => switch (language) {
            .ruby => if (scanIdentifier(scanner, language)) |_| return .{ .class = .constant },
            .haskell => if (scanner.consume(':')) return .{ .mode = .{ .haskell_signature = .{} } },
            else => {},
        },
        '@' => if (language == .ruby and scanIdentifier(scanner, language) != null)
            return .{ .class = .class_a },
        '`' => if (language == .haskell) if (scanner.consumeLineUntil('`')) |_|
            return .{ .class = .class_b },
        else => {},
    }
    return .none;
}

const Mode = union(enum) {
    fn class(self: Mode) ?Class {
        return switch (self) {
            inline else => |active| if (@hasDecl(@TypeOf(active), "class"))
                @TypeOf(active).class
            else
                active.class,
        };
    }

    fn finish(self: *Mode, scanner: *Scanner) bool {
        return switch (self.*) {
            inline else => |*active| active.finish(scanner),
        };
    }

    string_literal: struct {
        const class = Class.constant;
        delimiter: u8,
        fn finish(self: @This(), scanner: *Scanner) bool {
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
                    else => if (char == self.delimiter) return true,
                }
            }
            return false;
        }
    },

    line_comment: struct {
        const class = Class.comment;
        fn finish(self: @This(), scanner: *Scanner) bool {
            _ = self;
            while (scanner.peek()) |char| switch (char) {
                '\n' => break,
                '<', '&' => return false,
                else => scanner.eat(),
            };
            return true;
        }
    },

    haskell_signature: struct {
        class: ?Class = null,
        fn finish(self: *@This(), scanner: *Scanner) bool {
            if (scanIdentifier(scanner, .haskell)) |_| {
                self.class = .class_a;
                return scanner.peekEol();
            }
            self.class = null;
            while (scanner.peek()) |char| switch (char) {
                '\n' => break,
                '<', '&', 'a'...'z', 'A'...'Z' => return false,
                else => scanner.eat(),
            };
            return true;
        }
    },

    scheme_quote: struct {
        const class = Class.class_b;
        depth: u32 = 0,
        fn finish(self: *@This(), scanner: *Scanner) bool {
            if (self.depth == 0 and scanner.peek() != '(') {
                _ = scanIdentifier(scanner, .scheme);
                return true;
            }
            while (scanner.peek()) |char| : (scanner.eat()) switch (char) {
                '\n', '<', '&' => return false,
                '(' => self.depth += 1,
                ')' => {
                    self.depth -= 1;
                    if (self.depth == 0) {
                        scanner.eat();
                        return true;
                    }
                },
                else => {},
            };
            return true;
        }
    },
};

fn isWordCharacter(char: ?u8) bool {
    return switch (char orelse return false) {
        'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

fn scanIdentifier(scanner: *Scanner, language: Language) ?[]const u8 {
    switch (scanner.peek() orelse return null) {
        '0'...'9' => return null,
        else => {},
    }
    const text = scanRestOfIdentifier(scanner, language, scanner.offset);
    return if (text.len == 0) null else text;
}

fn scanRestOfIdentifier(scanner: *Scanner, language: Language, start: usize) []const u8 {
    while (scanner.peek()) |c| : (scanner.eat()) switch (c) {
        'a'...'z', 'A'...'Z', '_' => {},
        '0'...'9' => if (scanner.offset == start) break,
        '-', '+', '=', '*', '/', '?', '!' => if (language != .scheme) break,
        else => break,
    };
    return scanner.source[start..scanner.offset];
}

fn renderForTest(writer: anytype, scanner: *Scanner, language: ?Language) !void {
    var highlighter = try render(writer, language);
    while (!scanner.eof()) {
        if (try highlighter.@"resume"(writer, scanner)) break;
    } else try highlighter.renderEnd(writer);
}

fn expect(expected_html: []const u8, source: []const u8, language: ?Language) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_html = std.ArrayList(u8).init(allocator);
    try renderForTest(actual_html.writer(), &scanner, language);
    try testing.expectEqualStrings(expected_html, actual_html.items);
}

fn expectFailure(expected_message: []const u8, source: []const u8, language: ?Language) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, renderForTest(std.io.null_writer, &scanner, language));
}

test "empty input" {
    try expect("<pre>\n<code></code>\n</pre>", "", null);
}

test "empty line" {
    try expect("<pre>\n<code></code>\n</pre>", "\n", null);
}

test "blank line" {
    try expect("<pre>\n<code>\n</code>\n</pre>", "\n\n", null);
}

test "two blank line" {
    try expect("<pre>\n<code>\n\n</code>\n</pre>", "\n\n\n", null);
}

test "fails on trailing spaces" {
    try expectFailure("<input>:1:1: \" \": trailing whitespace", " ", null);
}

test "fails on trailing spaces after text" {
    try expectFailure("<input>:2:4: \"   \": trailing whitespace", "\nfoo   \n", null);
}

test "one line" {
    try expect("<pre>\n<code>Foo</code>\n</pre>", "Foo", null);
}

test "escape with entities" {
    try expect("<pre>\n<code>&lt;&amp;></code>\n</pre>", "<&>", null);
}

test "two keywords in a row" {
    try expect("<pre>\n<code><span class=\"kw\">def def</span></code>\n</pre>", "def def", .ruby);
}

test "two keywords on separate lines" {
    try expect("<pre>\n<code><span class=\"kw\">def\ndef</span></code>\n</pre>", "def\ndef", .ruby);
}

test "two keywords on separate lines with indent" {
    try expect("<pre>\n<code><span class=\"kw\">def\n  def</span></code>\n</pre>", "def\n  def", .ruby);
}

test "two keywords on separate lines with blank" {
    try expect("<pre>\n<code><span class=\"kw\">def\n\ndef</span></code>\n</pre>", "def\n\ndef", .ruby);
}

test "highlight ruby" {
    try expect(
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

test "highlight haskell" {
    try expect(
        \\<pre>
        \\<code><span class="kw">import</span> Foo
        \\bar :: <span class="ca">This</span> -> <span class="ca">That</span>
        \\bar x = x <span class="cb">`qux`</span> <span class="cn">123</span></code>
        \\</pre>
    ,
        \\import Foo
        \\bar :: This -> That
        \\bar x = x `qux` 123
    , .haskell);
}
