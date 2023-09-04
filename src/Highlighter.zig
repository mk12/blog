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

// REMEMBER TO POP STASH

active: bool = false,
language: ?Language = null,
first_line: bool = false,
current_class: ?Class = null,
pending_whitespace: ?[]const u8 = null,

pub const Language = enum {
    c,
    ruby,
    scheme,

    pub fn from(str: []const u8) ?Language {
        return std.meta.stringToEnum(Language, str);
    }
};

const Class = enum {
    kw, // keyword
    co, // comment
    cn, // constant
    st, // string
};

fn keywords(comptime language: Language) type {
    return std.ComptimeStringMap(void, switch (language) {
        .c => .{
            .{"void"},
            .{"int"},
            .{"char"},
        },
        .ruby => .{
            .{"def"},
            .{"end"},
            .{"test"},
        },
        .scheme => .{
            .{"define"},
        },
    });
}

pub fn begin(self: *Highlighter, writer: anytype, language: ?Language) !void {
    try writer.writeAll("<pre>\n<code>");
    self.active = true;
    self.first_line = true;
    self.language = language;
}

pub fn end(self: *Highlighter, writer: anytype) !void {
    try self.flush(writer);
    try writer.writeAll("</code>\n</pre>");
    self.active = false;
}

pub fn renderLine(self: *Highlighter, writer: anytype, scanner: *Scanner) !void {
    assert(self.current_class == null);
    if (!self.first_line) try writer.writeByte('\n');
    self.first_line = false;
    const language = self.language orelse {
        var offset: usize = scanner.offset;
        const end_offset = while (true) {
            const char = scanner.next() orelse break scanner.offset;
            const entity = switch (char) {
                '\n' => break scanner.offset - 1,
                '<' => "&lt;",
                '&' => "&amp;",
                else => continue,
            };
            try writer.writeAll(scanner.source[offset .. scanner.offset - 1]);
            try writer.writeAll(entity);
            offset = scanner.offset;
        };
        try writer.writeAll(scanner.source[offset..end_offset]);
        return;
    };
    while (true) {
        const start = scanner.offset;
        const char = scanner.next() orelse break;
        // Doing all this in renderLine instead of separtae next() method
        // so that it can just call self.write repeatedly if necessary, for
        // entities and for escapes etc.
        // Trying to do lanague-general things first, then some language specific
        // after.
        // NOT following the "find start after" text model, should be able to
        // identify each token one after the other. Unlike markdown where end
        // of text is purely defined as the start of nontext.

        // NEW IDEA
        // =========
        // instead of calling next() which returns class (doesn't work for strings with entities, escapes)
        // how about calling function which may write 1+ times, and do that in a loop
        switch (char) {
            '\n' => break,
            '<' => try self.write(writer, "&lt;", null),
            '&' => try self.write(writer, "&amp;", null),
            '0'...'9' => {
                while (scanner.peek()) |ch| switch (ch) {
                    '0'...'9', '.', '_' => scanner.eat(),
                    else => break,
                };
                try self.write(writer, scanner.source[start..scanner.offset], .cn);
            },
            ' ' => {
                while (scanner.peek()) |ch| switch (ch) {
                    ' ' => scanner.eat(),
                    else => break,
                };
                try self.writeWhitespace(scanner.source[start..scanner.offset]);
            },
            '"' => {
                var escape = false;
                while (scanner.next()) |ch| {
                    if (escape) {
                        escape = false;
                        continue;
                    }
                    switch (ch) {
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
                while (scanner.next()) |ch| {
                    if (escape) {
                        escape = false;
                        continue;
                    }
                    switch (ch) {
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
                while (scanner.peek()) |ch| switch (ch) {
                    'a'...'z', 'A'...'Z', '_' => scanner.eat(),
                    '-' => if (language == .scheme) scanner.eat() else break,
                    else => break,
                };
                const text = scanner.source[start..scanner.offset];
                const kw = switch (language) {
                    inline else => |lang| keywords(lang).has(text),
                };
                try self.write(writer, text, if (kw) .kw else null);
            },
            '/' => {
                if (language == .c and scanner.peek() == '/') {
                    while (scanner.peek()) |ch| switch (ch) {
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
                    break try self.write(writer, scanner.consumeUntilEol(), .co);
                } else {
                    // TODO remove
                    try self.write(writer, scanner.source[start..scanner.offset], null);
                }
            },
            // TODO handle @, : in ruby
            '(', ')', ',', '*', '.', '-', '+', '=', ':', ';', '{', '}', '[', ']', '@', '?' => try self.write(writer, scanner.source[start..scanner.offset], null),
            else => return scanner.fail("highlighter encountered unexpected character: '{c}'", .{char}),
            // TODO one char at a time like this maybe not ideal?
            // maybe indicates actually text-in-between model is right?
            // else => try self.write(writer, scanner.source[start..scanner.offset], .none),
        }
    }
    try self.flush(writer);
}

fn writeWhitespace(self: *Highlighter, whitespace: []const u8) !void {
    assert(self.pending_whitespace == null);
    self.pending_whitespace = whitespace;
}

fn write(self: *Highlighter, writer: anytype, text: []const u8, maybe_class: ?Class) !void {
    if (maybe_class != self.current_class) {
        try self.flush(writer);
        if (maybe_class) |class| {
            try fmt.format(writer, "<span class=\"{s}\">", .{@tagName(class)});
            self.current_class = class;
        }
    } else {
        try self.flushWhitespace(writer);
    }
    try writer.writeAll(text);
}

fn flush(self: *Highlighter, writer: anytype) !void {
    try self.flushSpanTag(writer);
    try self.flushWhitespace(writer);
}

fn flushSpanTag(self: *Highlighter, writer: anytype) !void {
    if (self.current_class) |_| {
        try writer.writeAll("</span>");
        self.current_class = null;
    }
}

fn flushWhitespace(self: *Highlighter, writer: anytype) !void {
    if (self.pending_whitespace) |space| {
        try writer.writeAll(space);
        self.pending_whitespace = null;
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
