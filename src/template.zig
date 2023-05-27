// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const EnumSet = std.enums.EnumSet;
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
};

const Token = struct {
    span: Scanner.Span,
    value: TokenValue,
};

fn scan(scanner: *Scanner) !?Token {
    const pos = scanner.pos;
    const brace: u8 = '{';
    while (true) {
        if (scanner.eof() or (scanner.peek(0) == brace and scanner.peek(1) == brace)) {
            if (scanner.pos.offset != pos.offset) {
                const span = scanner.makeSpan(pos, scanner.pos);
                return .{ .span = span, .value = .{ .text = span.text } };
            }
            break;
        }
        _ = scanner.eat();
    }
    if (scanner.eof()) return null;
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
    return .{ .span = scanner.makeSpan(pos, scanner.pos), .value = value };
}

fn scanIdentifier(scanner: *Scanner) ![]const u8 {
    const pos = scanner.pos;
    while (scanner.peek(0)) |char| {
        switch (char) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.' => {},
            else => break,
        }
        _ = scanner.eat();
    }
    if (scanner.pos.offset == pos.offset)
        return scanner.fail("expected an identifier", .{});
    return scanner.source[pos.offset..scanner.pos.offset];
}

test "scan empty string" {
    const source = "";
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    try testing.expectEqual(@as(?Token, null), try scan(&scanner));
}

test "scan text" {
    const source = "foo\n";
    const expected = Token{
        .span = Scanner.Span{
            .pos = Scanner.Position{ .offset = 0, .line = 1, .column = 1 },
            .text = "foo\n",
        },
        .value = .{ .text = "foo\n" },
    };
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    try testing.expectEqualDeep(@as(?Token, expected), try scan(&scanner));
    try testing.expectEqual(@as(?Token, null), try scan(&scanner));
}

fn scanTokenValues(allocator: Allocator, scanner: *Scanner) !std.ArrayList(TokenValue) {
    var list = std.ArrayList(TokenValue).init(allocator);
    errdefer list.deinit();
    while (try scan(scanner)) |token| {
        try list.append(token.value);
    }
    return list;
}

test "scan text and variable" {
    const source = "Hello {{ name }}!";
    const expected = [_]TokenValue{
        .{ .text = "Hello " },
        .{ .variable = "name" },
        .{ .text = "!" },
    };
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    const actual = try scanTokenValues(testing.allocator, &scanner);
    defer actual.deinit();
    try testing.expectEqualDeep(@as([]const TokenValue, &expected), actual.items);
}

fn find(substring: []const u8, source: []const u8, occurrence: usize) ![]const u8 {
    var count: usize = 0;
    var offset: usize = 0;
    while (true) {
        offset = std.mem.indexOfPos(u8, source, offset, substring) orelse
            return error.SubstringNotFound;
        if (count == occurrence) break;
        count += 1;
        offset += 1;
    }
    const in_source = source[offset .. offset + substring.len];
    try testing.expectEqualStrings(substring, in_source);
    return in_source;
}

test "scan all kinds of tokens" {
    const source =
        \\{{ include "base.html" }}
        \\{{ define var }}
        \\    {{ for thing }}
        \\        Value: {{if bar}}{{.}}{{else}}Fallback{{end}},
        \\    {{ end }}
        \\{{ end }}
    ;
    const expected = [_]TokenValue{
        .{ .include = try find("base.html", source, 0) },
        .{ .text = try find("\n", source, 0) },
        .{ .define = try find("var", source, 0) },
        .{ .text = try find("\n    ", source, 0) },
        .{ .start = try find("thing", source, 0) },
        .{ .text = try find("\n        Value: ", source, 0) },
        .{ .start = try find("bar", source, 0) },
        .{ .variable = try find(".", source, 1) },
        .@"else",
        .{ .text = try find("Fallback", source, 0) },
        .end,
        .{ .text = try find(",\n    ", source, 0) },
        .end,
        .{ .text = try find("\n", source, 4) },
        .end,
    };
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    const actual = try scanTokenValues(testing.allocator, &scanner);
    defer actual.deinit();
    try testing.expectEqualSlices(TokenValue, &expected, actual.items);
}

const Definition = struct {
    variable: Variable,
    body: Template,
};

const CommandValue = union(enum) {
    text: []const u8,
    include: union(enum) {
        unresolved: []const u8,
        resolved: *const Template,
    },
    variable: Variable,
    control: struct {
        variable: Variable,
        body: Template,
        else_body: ?Template,
    },
};

const Command = struct {
    pos: Scanner.Position,
    value: CommandValue,
};

pub fn parse(allocator: Allocator, scanner: *Scanner) !Template {
    return parseUntil(allocator, scanner, .eof);
}

fn parseUntil(allocator: Allocator, scanner: *Scanner, terminator: Terminator) !Template {
    const terminators = EnumSet(Terminator).initOne(terminator);
    const result = try parseUntilAny(allocator, scanner, terminators);
    return result.template;
}

const Terminator = enum { end, @"else", eof };
const Result = struct { template: Template, terminator: Terminator };

fn parseUntilAny(
    allocator: Allocator,
    scanner: *Scanner,
    allowed_terminators: EnumSet(Terminator),
) Scanner.Error!Result {
    _ = allowed_terminators;
    var definitions = std.ArrayList(Definition).init(allocator);
    errdefer definitions.deinit();
    var commands = std.ArrayList(Command).init(allocator);
    errdefer commands.deinit();
    var terminator: Terminator = .eof;
    while (try scan(scanner)) |token| {
        const command_value: CommandValue = switch (token.value) {
            .define => |variable| {
                try definitions.append(.{
                    .variable = variable,
                    .body = try parseUntil(allocator, scanner, .end),
                });
                continue;
            },
            .@"else", .end => {
                terminator = std.meta.stringToEnum(Terminator, @tagName(token.value)).?;
                break;
            },
            .text => |text| .{ .text = text },
            .include => |path| .{ .include = .{ .unresolved = path } },
            .variable => |variable| .{ .variable = variable },
            .start => |variable| blk: {
                const result = try parseUntilAny(
                    allocator,
                    scanner,
                    EnumSet(Terminator).init(.{ .end = true, .@"else" = true }),
                );
                break :blk .{
                    .control = .{
                        .variable = variable,
                        .body = result.template,
                        .else_body = switch (result.terminator) {
                            .@"else" => try parseUntil(allocator, scanner, .end),
                            else => null,
                        },
                    },
                };
            },
        };
        try commands.append(.{ .pos = token.span.pos, .value = command_value });
    }
    return Result{
        .template = Template{ .definitions = definitions, .commands = commands },
        .terminator = terminator,
    };
}
