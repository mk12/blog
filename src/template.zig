// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const EnumSet = std.enums.EnumSet;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Template = @This();

filename: []const u8,
definitions: std.ArrayListUnmanaged(Definition) = .{},
commands: std.ArrayListUnmanaged(Command) = .{},

const Variable = []const u8;

const TokenValue = union(enum) {
    text: []const u8,
    include: []const u8, // template path
    variable: Variable,
    define: Variable,
    start: Variable, // "if" or "range"
    @"else",
    end,
};

const Token = struct {
    value: TokenValue,
    location: Reporter.Location,
};

fn scan(scanner: *Scanner) !?Token {
    const location = scanner.location;
    const start = scanner.offset;
    const brace: u8 = '{';
    while (true) {
        const char1 = scanner.peek(0);
        const char2 = scanner.peek(1);
        if (char1 == null or (char1 == brace and char2 == brace)) {
            if (scanner.offset != start) {
                const text = scanner.source[start..scanner.offset];
                return .{ .value = .{ .text = text }, .location = location };
            }
            break;
        }
        scanner.eat(char1.?);
    }
    if (scanner.eof()) return null;
    try scanner.expect("{{");
    scanner.skipWhitespace();
    const word = try scanIdentifier(scanner);
    scanner.skipWhitespace();
    const Kind = enum { variable, include, define, @"if", range, @"else", end };
    const kind = std.meta.stringToEnum(Kind, word) orelse .variable;
    const value: TokenValue = switch (kind) {
        .variable => .{ .variable = word },
        .include => .{
            .include = blk: {
                try scanner.expect("\"");
                const path = try scanner.until('"');
                scanner.skipWhitespace();
                break :blk path.text;
            },
        },
        .define => .{
            .define = blk: {
                const variable = try scanIdentifier(scanner);
                scanner.skipWhitespace();
                break :blk variable;
            },
        },
        .@"if", .range => .{
            .start = blk: {
                const variable = try scanIdentifier(scanner);
                scanner.skipWhitespace();
                break :blk variable;
            },
        },
        .@"else" => .@"else",
        .end => .end,
    };
    try scanner.expect("}}");
    return Token{ .location = location, .value = value };
}

fn scanIdentifier(scanner: *Scanner) ![]const u8 {
    const start = scanner.offset;
    while (scanner.peek(0)) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.' => scanner.eat(char),
        else => break,
    };
    if (scanner.offset == start) return scanner.fail("expected an identifier", .{});
    return scanner.source[start..scanner.offset];
}

test "scan empty string" {
    const source = "";
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try testing.expectEqual(@as(?Token, null), try scan(&scanner));
}

test "scan text" {
    const source = "foo\n";
    const expected = Token{
        .location = .{ .line = 1, .column = 1 },
        .value = .{ .text = "foo\n" },
    };
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const actual = try scanTokenValues(testing.allocator, &scanner);
    defer actual.deinit();
    try testing.expectEqualDeep(@as([]const TokenValue, &expected), actual.items);
}

// TODO custom assertion instead of doing all this "find" stuff
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const actual = try scanTokenValues(testing.allocator, &scanner);
    defer actual.deinit();
    try testing.expectEqualSlices(TokenValue, &expected, actual.items);
}

const Definition = struct {
    variable: Variable,
    body: Template,
};

const Command = struct {
    location: Reporter.Location,
    value: CommandValue,
};

const CommandValue = union(enum) {
    text: []const u8,
    variable: Variable,
    include: *const Template,
    control: struct {
        variable: Variable,
        body: Template,
        else_body: ?Template,
    },
};

pub fn deinit(self: *Template, allocator: Allocator) void {
    for (self.definitions.items) |*definition| {
        definition.body.deinit(allocator);
    }
    for (self.commands.items) |*command| {
        switch (command.value) {
            .control => |*control| {
                control.body.deinit(allocator);
                if (control.else_body) |*body| body.deinit(allocator);
            },
            else => {},
        }
    }
    self.definitions.deinit(allocator);
    self.commands.deinit(allocator);
}

pub fn parse(
    allocator: Allocator,
    scanner: *Scanner,
    include_map: ?std.StringHashMap(Template),
) !Template {
    const ctx = ParseContext{ .allocator = allocator, .scanner = scanner, .include_map = include_map };
    return parseUntil(ctx, .eof);
}

const ParseContext = struct {
    allocator: Allocator,
    scanner: *Scanner,
    include_map: ?std.StringHashMap(Template),
};

fn parseUntil(ctx: ParseContext, terminator: Terminator) !Template {
    const terminators = EnumSet(Terminator).initOne(terminator);
    const result = try parseUntilAny(ctx, terminators);
    return result.template;
}

const Terminator = enum { end, @"else", eof };
const ParseError = Reporter.Error || Allocator.Error;
const ParseResult = ParseError!struct { template: Template, terminator: Terminator };

fn parseUntilAny(ctx: ParseContext, allowed_terminators: EnumSet(Terminator)) ParseResult {
    const scanner = ctx.scanner;
    var template = Template{ .filename = scanner.filename };
    errdefer template.deinit(ctx.allocator);
    var terminator = Terminator.eof;
    var terminator_pos: ?Reporter.Location = null;
    while (try scan(scanner)) |token| {
        const command_value: CommandValue = switch (token.value) {
            .define => |variable| {
                try template.definitions.append(ctx.allocator, Definition{
                    .variable = variable,
                    .body = try parseUntil(ctx, .end),
                });
                continue;
            },
            .end => {
                terminator = .end;
                terminator_pos = token.location;
                break;
            },
            .@"else" => {
                terminator = .@"else";
                terminator_pos = token.location;
                break;
            },
            .text => |text| .{ .text = text },
            .variable => |variable| .{ .variable = variable },
            .include => |path| .{
                .include = ctx.include_map.?.getPtr(path) orelse
                    return scanner.failAt(token.location, "{s}: template not found", .{path}),
            },
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
        try template.commands.append(ctx.allocator, Command{
            .location = token.location,
            .value = command_value,
        });
    }
    if (!allowed_terminators.contains(terminator)) {
        const location = terminator_pos orelse scanner.location;
        return scanner.failAt(location, "unexpected {s}", .{
            switch (terminator) {
                .end => "{{ end }}",
                .@"else" => "{{ else }}",
                .eof => "EOF",
            },
        });
    }
    return .{ .template = template, .terminator = terminator };
}

test "parse text" {
    const source = "foo\n";
    const expected_definitions = [_]Definition{};
    const expected_commands = [_]Command{
        .{
            .location = .{ .line = 1, .column = 1 },
            .value = .{ .text = try find("foo\n", source, 0) },
        },
    };
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var template = try parse(testing.allocator, &scanner, null);
    defer template.deinit(testing.allocator);
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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var include_map = std.StringHashMap(Template).init(testing.allocator);
    defer include_map.deinit();
    try include_map.put("base.html", undefined);
    const base_template: *const Template = include_map.getPtr("base.html").?;

    var template = try parse(testing.allocator, &scanner, include_map);
    defer template.deinit(testing.allocator);

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
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, parse(testing.allocator, &scanner, null));
}

test "unterminated command" {
    const source =
        \\Missing closing {{ braces.
    ;
    const expected_error =
        \\<input>:1:27: unexpected EOF, expected "}}"
    ;
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, parse(testing.allocator, &scanner, null));
}

test "missing end" {
    const source =
        \\It's not terminated! {{ if foo }} oops.
    ;
    const expected_error =
        \\<input>:1:40: unexpected EOF
    ;
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, parse(testing.allocator, &scanner, null));
}

test "unexpected end" {
    const source =
        \\Hello {{ if logged_in }}{{ username}}{{ else }}Anonymous{{ end }}
        \\{{ end }}
    ;
    const expected_error =
        \\<input>:2:1: unexpected {{ end }}
    ;
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_error, parse(testing.allocator, &scanner, null));
}

test "invalid include" {
    const source =
        \\Some text before.
        \\{{ include "does_not_exist" }}
    ;
    const expected_error =
        \\<input>:2:1: does_not_exist: template not found
    ;
    var reporter = Reporter{};
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var include_map = std.StringHashMap(Template).init(testing.allocator);
    defer include_map.deinit();
    try reporter.expectFailure(expected_error, parse(testing.allocator, &scanner, include_map));
}

pub const Value = union(enum) {
    string: []const u8,
    bool: bool,
    template: *const Template,
    array: std.ArrayListUnmanaged(Value),
    dictionary: std.StringHashMapUnmanaged(Value),

    fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string, .bool, .template => {},
            .array => |*array| {
                for (array.items) |*value| value.deinit(allocator);
                array.deinit(allocator);
            },
            .dictionary => |*dictionary| {
                var iter = dictionary.valueIterator();
                while (iter.next()) |value| value.deinit(allocator);
                dictionary.deinit(allocator);
            },
        }
    }

    fn lookup(self: Value, name: []const u8) Value {
        _ = name;
        _ = self;
        unreachable;
    }
};

// const Scope = std.SinglyLinkedList(Dictionary);

// const ExecuteContext = struct {
//     allocator: Allocator,
//     variables: Value,
//     // scratch: std.SegmentedList(u8, 256),
//     reporter: *Reporter,
// };

const Scope = struct {
    parent: ?*const Scope,
    value: Value,
};

// TODO 2 things:
// - pass scratch buffer for definitions?
// - scope chaining. can use call stack somehow?
pub fn execute(self: Template, allocator: Allocator, scope: Scope, writer: anytype, reporter: *Reporter) !void {
    // var buffer = std.SegmentedList(u8, 128){};
    // for (self.definitions.items) |definition| {
    //     const start = buffer.items.len;
    //     _ = start;
    //     try definition.body.execute(allocator, variables, buffer.writer());
    //     const end = buffer.items.len;
    //     _ = end;
    //     // TODO: Scope type which is a linked list of dictionaries.
    //     // try variables.put(definition.variable,
    // }
    for (self.commands.items) |command| {
        switch (command.value) {
            .text => |text| try writer.writeAll(text),
            .include => |template| try template.execute(allocator, scope, writer),
            .variable => |variable| {
                // TODO lookup. Handle "." too
                const value = Value{ .string = "hi" };
                switch (value) {
                    .string => |string| try writer.writeAll(string),
                    .template => |template| try template.execute(allocator, scope, writer, reporter),
                    else => return reporter.fail(
                        self.filename,
                        command.location,
                        "{s}: expected string variable, got {s}",
                        .{ variable.name, @tagName(value) },
                    ),
                }
            },
            .control => |control| {
                // TODO lookup.
                const value = Value{ .dictionary = .{} };
                switch (value) {
                    .bool => |val| if (val)
                        control.body.execute(allocator, scope, writer, reporter)
                    else if (control.else_body) |else_body|
                        else_body.execute(allocator, scope, writer, reporter),
                    .array => |array| if (array.len == 0) {
                        if (control.else_body) |else_body|
                            else_body.execute(allocator, scope, writer, reporter);
                    } else for (array.items) |item| {
                        const new_scope = Scope{ .parent = scope, .value = item };
                        control.body.execute(allocator, new_scope, writer, reporter);
                    },
                    else => {
                        const new_scope = Scope{ .parent = scope, .value = value };
                        control.body.execute(allocator, new_scope, writer, reporter);
                    },
                }
            },
        }
    }
}

// test "execute text" {
//     const source =
//         \\Hello world!
//     ;
//     var scanner = { .source = source };
//     var template = try parse(testing.allocator, &scanner, null);
//     defer template.deinit(testing.allocator);
//     var buffer = std.ArrayList(u8).init(testing.allocator);
//     var dict = Value{ .dictionary = .{} };
//     defer dict.deinit(testing.allocator);
//     try template.execute(testing.allocator, dict, buffer.writer());
// }
