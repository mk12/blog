// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const Scanner = @import("Scanner.zig");
const Template = @This();

definitions: std.ArrayList(Definition),
commands: std.ArrayList(Command),

const Variable = []const u8;

const TokenValue = union(enum) {
    text: []const u8,
    define: Variable,
    include: []const u8,
    variable: Variable,
    start: Variable,
    @"else": void,
    end: void,
    eof: void,
};

const Token = struct {
    pos: Scanner.Position,
    value: TokenValue,
};

fn scan(scanner: *Scanner) !Token {
    const pos = scanner.pos;
    const brace: u8 = '{';
    while (true) {
        if (scanner.eof() or (scanner.peek(0) == brace and scanner.peek(1) == brace)) {
            if (scanner.pos.offset != pos.offset) return .{
                .pos = pos,
                .value = .{ .text = scanner.source[pos.offset..scanner.pos.offset] },
            };
            break;
        }
        _ = scanner.eat();
    }
    if (scanner.eof()) return .{ .pos = pos, .value = .eof };
    try scanner.consume("{{");
    scanner.skipWhitespace();
    const word = try scanIdentifier(scanner);
    scanner.skipWhitespace();
    const Kind = enum { define, include, start, @"else", end, variable };
    const map = std.ComptimeStringMap(Kind, .{
        .{ "define", .define },
        .{ "include", .include },
        .{ "if", .start },
        .{ "for", .start },
        .{ "else", .@"else" },
        .{ "end", .end },
    });
    const kind = map.get(word) orelse .variable;
    const value: TokenValue = switch (kind) {
        .variable => .{ .variable = word },
        .define => .{
            .define = blk: {
                const variable = try scanIdentifier(scanner);
                scanner.skipWhitespace();
                break :blk variable;
            },
        },
        .include => .{
            .include = blk: {
                try scanner.consume("\"");
                const path = try scanner.consumeUntil('"');
                scanner.skipWhitespace();
                break :blk path.text;
            },
        },
        .start => .{
            .start = blk: {
                const variable = try scanIdentifier(scanner);
                scanner.skipWhitespace();
                break :blk variable;
            },
        },
        .@"else" => .@"else",
        .end => .end,
    };
    try scanner.consume("}}");
    return .{ .pos = pos, .value = value };
}

fn scanIdentifier(scanner: *Scanner) ![]const u8 {
    const pos = scanner.pos;
    while (true) {
        switch (scanner.eat() orelse return scanner.fail("unexpected EOF", .{})) {
            'A'...'Z' => {},
            'a'...'z' => {},
            '0'...'9' => {},
            '_' => {},
            else => break,
        }
    }
    if (scanner.pos.offset == pos.offset)
        return scanner.fail("expected an identifier", .{});
    return scanner.source[pos.offset..scanner.pos.offset];
}

test "scan empty string" {
    var scanner = Scanner.init(testing.allocator, "");
    defer scanner.deinit();
    try testing.expectEqual(Token{
        .pos = Scanner.Position{ .offset = 0, .line = 1, .column = 1 },
        .value = .eof,
    }, try scan(&scanner));
}

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
    //     text_cmd.value.text = mem.trimRight(u8, text, "\n");
    //     try commands.append(text_cmd);
    // }
    return Template{ .definitions = definitions, .commands = commands };
}
