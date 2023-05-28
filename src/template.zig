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
    pos: Scanner.Position,
    value: TokenValue,
};

fn scan(scanner: *Scanner) !?Token {
    const pos = scanner.pos;
    const brace: u8 = '{';
    while (true) {
        if (scanner.eof() or (scanner.peek(0) == brace and scanner.peek(1) == brace)) {
            if (scanner.pos.offset != pos.offset) {
                const span = scanner.makeSpan(pos, scanner.pos);
                return .{ .pos = span.pos, .value = .{ .text = span.text } };
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
        .{ "range", .start },
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
        .pos = .{ .offset = 0, .line = 1, .column = 1 },
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

test "scan all kinds of stuff" {
    const source =
        \\{{ include "base.html" }}
        \\{{ define var }}
        \\    {{ range thing }}
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
    include: *const Template,
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

pub fn deinit(self: *Template) void {
    for (self.definitions.items) |*definition| {
        definition.body.deinit();
    }
    for (self.commands.items) |*command| {
        switch (command.value) {
            .control => |*control| {
                control.body.deinit();
                if (control.else_body) |*body| body.deinit();
            },
            else => {},
        }
    }
    self.definitions.deinit();
    self.commands.deinit();
}

pub fn parse(
    allocator: Allocator,
    scanner: *Scanner,
    include_map: ?*const std.StringHashMap(Template),
) !Template {
    const ctx = Context{ .allocator = allocator, .scanner = scanner, .include_map = include_map };
    return parseUntil(ctx, .eof);
}

pub const Context = struct {
    allocator: Allocator,
    scanner: *Scanner,
    include_map: ?*const std.StringHashMap(Template),
};

fn parseUntil(ctx: Context, terminator: Terminator) !Template {
    const terminators = EnumSet(Terminator).initOne(terminator);
    const result = try parseUntilAny(ctx, terminators);
    return result.template;
}

const Terminator = enum { end, @"else", eof };
const Result = struct { template: Template, terminator: Terminator };

fn parseUntilAny(ctx: Context, allowed_terminators: EnumSet(Terminator)) Scanner.Error!Result {
    var template = Template{
        .definitions = std.ArrayList(Definition).init(ctx.allocator),
        .commands = std.ArrayList(Command).init(ctx.allocator),
    };
    errdefer template.deinit();
    var terminator: Terminator = .eof;
    var terminator_pos: ?Scanner.Position = null;
    const scanner = ctx.scanner;
    while (try scan(scanner)) |token| {
        const command_value: CommandValue = switch (token.value) {
            .define => |variable| {
                try template.definitions.append(.{
                    .variable = variable,
                    .body = try parseUntil(ctx, .end),
                });
                continue;
            },
            .@"else", .end => {
                terminator = std.meta.stringToEnum(Terminator, @tagName(token.value)).?;
                terminator_pos = token.pos;
                break;
            },
            .text => |text| .{ .text = text },
            .include => |path| .{
                .include = ctx.include_map.?.getPtr(path) orelse
                    return scanner.failAt(token.pos, "{s}: template not found", .{path}),
            },
            .variable => |variable| .{ .variable = variable },
            .start => |variable| blk: {
                const end_or_else = EnumSet(Terminator).init(.{ .end = true, .@"else" = true });
                const result = try parseUntilAny(ctx, end_or_else);
                break :blk .{
                    .control = .{
                        .variable = variable,
                        .body = result.template,
                        .else_body = switch (result.terminator) {
                            .@"else" => try parseUntil(ctx, .end),
                            else => null,
                        },
                    },
                };
            },
        };
        try template.commands.append(.{ .pos = token.pos, .value = command_value });
    }
    if (!allowed_terminators.contains(terminator)) {
        const pos = terminator_pos orelse scanner.pos;
        return scanner.failAt(pos, "unexpected {s}", .{
            switch (terminator) {
                .end => "{{ end }}",
                .@"else" => "{{ else }}",
                .eof => "EOF",
            },
        });
    }
    return Result{
        .template = template,
        .terminator = terminator,
    };
}

test "parse text" {
    const source = "foo\n";
    const expected_definitions = [_]Definition{};
    const expected_commands = [_]Command{
        .{
            .pos = .{ .offset = 0, .line = 1, .column = 1 },
            .value = .{ .text = try find("foo\n", source, 0) },
        },
    };
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    var template = try parse(testing.allocator, &scanner, null);
    defer template.deinit();
    try testing.expectEqualSlices(Definition, &expected_definitions, template.definitions.items);
    try testing.expectEqualSlices(Command, &expected_commands, template.commands.items);
}

test "parse all kinds of stuff" {
    const source =
        \\{{ include "base.html" }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}Fallback{{end}},
        \\    {{ end }}
        \\{{ end }}
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = true });
    defer scanner.deinit();
    var include_map = std.StringHashMap(Template).init(testing.allocator);
    defer include_map.deinit();
    try include_map.put("base.html", undefined);
    const base_template: *const Template = include_map.getPtr("base.html").?;

    var template = try parse(testing.allocator, &scanner, &include_map);
    defer template.deinit();

    const definitions = template.definitions.items;
    try testing.expectEqual(@as(usize, 1), definitions.len);
    const define_var = definitions[0];
    try testing.expectEqualStrings("var", define_var.variable);
    try testing.expectEqual(@as(usize, 0), define_var.body.definitions.items.len);
    const var_body = define_var.body.commands.items;
    try testing.expectEqual(@as(usize, 3), var_body.len);
    try testing.expectEqualStrings("\n    ", var_body[0].value.text);
    const range_thing = var_body[1].value.control;
    try testing.expectEqualStrings("\n", var_body[2].value.text);
    try testing.expectEqualStrings("thing", range_thing.variable);
    try testing.expectEqual(@as(usize, 0), range_thing.body.definitions.items.len);
    const range_body = range_thing.body.commands.items;
    try testing.expectEqual(@as(usize, 3), range_body.len);
    try testing.expectEqual(@as(?Template, null), range_thing.else_body);
    try testing.expectEqualStrings("\n        Value: ", range_body[0].value.text);
    const if_bar = range_body[1].value.control;
    try testing.expectEqualStrings(",\n    ", range_body[2].value.text);
    try testing.expectEqual(@as(usize, 0), if_bar.body.definitions.items.len);
    try testing.expectEqual(@as(usize, 0), if_bar.else_body.?.definitions.items.len);
    const if_body = if_bar.body.commands.items;
    try testing.expectEqual(@as(usize, 1), if_body.len);
    try testing.expectEqualStrings(".", if_body[0].value.variable);
    const else_body = if_bar.else_body.?.commands.items;
    try testing.expectEqual(@as(usize, 1), else_body.len);
    try testing.expectEqualStrings("Fallback", else_body[0].value.text);

    const commands = template.commands.items;
    try testing.expectEqual(@as(usize, 2), commands.len);
    try testing.expectEqual(base_template, commands[0].value.include);
    try testing.expectEqualStrings("\n", commands[1].value.text);
}

test "invalid command" {
    const source =
        \\Too many words in {{ foo bar qux }}.
    ;
    const expected_error =
        \\<input>:1:26: expected "}}", got "ba"
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parse(testing.allocator, &scanner, null));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "unterminated command" {
    const source =
        \\Missing closing {{ braces.
    ;
    const expected_error =
        \\<input>:1:27: unexpected EOF while looking for "}}"
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parse(testing.allocator, &scanner, null));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "missing end" {
    const source =
        \\It's not terminated! {{ if foo }} oops.
    ;
    const expected_error =
        \\<input>:1:40: unexpected EOF
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parse(testing.allocator, &scanner, null));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "unexpected end" {
    const source =
        \\Hello {{ if logged_in }}{{ username}}{{ else }}Anonymous{{ end }}
        \\{{ end }}
    ;
    const expected_error =
        \\<input>:2:1: unexpected {{ end }}
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    try testing.expectError(error.ScanError, parse(testing.allocator, &scanner, null));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}

test "invalid include" {
    const source =
        \\Some text before.
        \\{{ include "does_not_exist" }}
    ;
    const expected_error =
        \\<input>:2:1: does_not_exist: template not found
    ;
    var scanner = Scanner.initForTest(source, .{ .log_error = false });
    defer scanner.deinit();
    var include_map = std.StringHashMap(Template).init(testing.allocator);
    defer include_map.deinit();
    try testing.expectError(error.ScanError, parse(testing.allocator, &scanner, &include_map));
    try testing.expectEqualStrings(expected_error, scanner.error_message.?);
}
