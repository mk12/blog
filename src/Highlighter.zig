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
    const start = scanner.offset;
    while (scanner.next()) |ch| if (ch == '\n') break;
    if (!self.first_line) try writer.writeByte('\n');
    self.first_line = false;
    try writer.writeAll(std.mem.trimRight(u8, scanner.source[start..scanner.offset], "\n"));
    // while (true) {
    //     const offset = scanner.offset;
    //     const token = self.next(scanner);
    //     if (token.start != offset)
    //         try self.write(writer, scanner.source[offset..token.start], .none);
    //     try self.write(writer, scanner.source[token.start..scanner.offset], token.)
    // }
}

fn write(self: *Highlighter, writer: anytype, text: []const u8, class: Class) !void {
    _ = class;
    _ = text;
    _ = writer;
    _ = self;
}

fn flush(self: *Highlighter, writer: anytype) !void {
    _ = writer;
    _ = self;
}

const Token = struct {
    start: usize,
    value: union(enum) {
        end_of_code,
        @"<",
        @"&",
        text: Class,
    },
};

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
    _ = scanner;
}
