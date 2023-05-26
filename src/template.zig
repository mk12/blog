// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Scanner = @import("Scanner.zig");
const Template = @This();

definitions: std.ArrayList(Definition),
commands: std.ArrayList(Command),

const Variable = []const u8;

const Token = struct {
    pos: Scanner.Position,
    value: union(enum) {
        text: []const u8,
        define: Variable,
        include: []const u8,
        variable: Variable,
        control: Variable,
        @"else": void,
        end: void,
        eof: void,
    },
};

const Definition = struct {
    variable: Variable,
    body: Template,
};

const Command = struct {
    pos: Scanner.Position,
    value: union(enum) {
        text: []const u8,
        include: union(enum) {
            unresolved: []const u8,
            resolved: *const Template,
        },
        variable: Variable,
        control: struct {
            variable: Variable,
            body: Template,
            elseBody: Template,
        },
    },
};

fn scan(scanner: *Scanner) !Token {
    const pos = scanner.pos;
    const char1 = scanner.eat() orelse
        return .{ .pos = pos, .value = .eof };
    const char2 = scanner.eat() orelse
        return .{ .pos = pos, .value = .{ .text = scanner.source[pos.offset..] } };
    if (!(char1 == '{' and char2 == '{')) {
        var prev = char2;
        _ = prev;
    }
    unreachable;
}

test "scan empty string" {
    var scanner = Scanner.init(testing.allocator, "");
    defer scanner.deinit();
    try testing.expectEqual(Token{
        .pos = Scanner.Position{ .offset = 0, .line = 1, .column = 1 },
        .value = .eof,
    }, try scan(&scanner));
}

pub fn parse(allocator: Allocator, scanner: *Scanner) !Template {
    var definitions = std.ArrayList(Definition).init(allocator);
    errdefer definitions.deinit();
    var commands = std.ArrayList(Command).init(allocator);
    errdefer commands.deinit();
    while (true) {}
    var text_start = scanner.pos;
    _ = text_start;
    var prev = null;
    while (scanner.eat()) |char| {
        if (prev == '{' and char == '{') break;
        prev = char;
    }
    // const text_cmd = Command{
    //     .pos = text_start,
    //     .value = .{ .text = text },
    // };
    // if (scanner.eof()) {
    //     text_cmd.value.text = std.mem.trimRight(u8, text, "\n");
    //     try commands.append(text_cmd);
    // }
    return Template{ .definitions = definitions, .commands = commands };
}
