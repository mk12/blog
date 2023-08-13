// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fmt = std.fmt;
const Scanner = @import("Scanner.zig");
const Highlighter = @This();

enabled: bool,
active: bool = false,
language: Language = .none,
first_line: bool = false,
class: Class = .none,

pub const Language = enum {
    none,
    c,
    ruby,
    scheme,

    pub fn from(str: []const u8) Language {
        return std.meta.stringToEnum(Language, str) orelse .none;
    }
};

pub fn begin(self: *Highlighter, writer: anytype, language: Language) !void {
    try writer.writeAll("<pre>\n<code>");
    self.active = true;
    self.first_line = true;
    self.language = if (self.enabled) language else .none;
}

pub fn end(self: *Highlighter, writer: anytype) !void {
    try self.flush(writer);
    try writer.writeAll("</code>\n</pre>");
    self.active = false;
}

pub fn renderLine(self: *Highlighter, writer: anytype, scanner: *Scanner) !void {
    if (!self.first_line) try writer.writeByte('\n');
    self.first_line = false;
    while (true) {
        const start = scanner.offset;
        const token = self.next(scanner);
        const text_before = scanner.source[start..token.offset];
        if (text_before.len != 0) try self.write(writer, text_before, .none);
        switch (token.value) {
            .eof, .@"\n" => break,
            .@"<" => try self.write(writer, "&lt;", token.class),
            .@"&" => try self.write(writer, "&amp;", token.class),
            .text => |text| try self.write(writer, text, token.class),
        }
    }
}

fn write(self: *Highlighter, writer: anytype, text: []const u8, class: Class) !void {
    _ = class;
    _ = self;
    try writer.writeAll(text);
}

fn flush(self: *Highlighter, writer: anytype) !void {
    _ = writer;
    _ = self;
}

const Token = struct {
    offset: usize,
    value: TokenValue,
    class: Class,
};

const TokenValue = union(enum) { eof, @"\n", @"<", @"&", text: []const u8 };

const Class = enum {
    none,
    whitespace,
    keyword,
    comment,
    constant,
    string,
};

fn next(self: *Highlighter, scanner: *Scanner) Token {
    _ = self;
    var offset: usize = undefined;
    const value: TokenValue = while (true) {
        offset = scanner.offset;
        const char = scanner.next() orelse break .eof;
        switch (char) {
            '\n' => break .@"\n",
            '&' => break .@"&",
            '<' => break .@"<",
            else => {},
        }
    };
    return Token{ .offset = offset, .value = value, .class = .none };
}
