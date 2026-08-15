// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements a templating system inspired by Go's text/template.
//! Templates must be parsed first, and then can be executed multiple times.
//!
//! The syntax is as follows:
//!
//!     {{ foo }}                              insert a variable
//!     {{ foo? }}                             allow undefined variables
//!     {{ foo ?? bar }}                       provide a fallback
//!     {{ if foo }}...{{ end }}               if statement
//!     {{ if foo == "bar" }}...{{ end }}      equality test
//!     {{ if foo }}...{{ else }}...{{ end }}  if-else statement
//!     {{ range foo }}...{{ end }}            range over a collection
//!     {{ template "file.html" }}             include another template
//!     {{ foo = bar }}                        define a reference variable
//!     {{ foo = "..." }}                      define a string variable
//!     {{ block foo }}...{{ end }}            define a Markdown variable
//!     {{ define foo }}...{{ end }}           define a template variable
//!
//! A value is either null, a bool, string, array of values, dictionary from
//! strings to values, pointer to a Value, sub-template, date, or Markdown.
//!
//! Everything is truthy except false, null, empty arrays, and empty strings.
//! Within if/range, {{ . }} is bound to the item. If the item is a dictionary,
//! its fields are brought into scope as well. {{ template "var" }} is actually
//! the same thing as {{ var }}, but it can refer to non [a-zA-Z0-9_] variables.
//!
//! When a command is preceded on its line only by whitespace, prior whitespace
//! (even before the line) is trimmed, similar to {{- foo }} in Go templates.
//!
//! You can express Jinja-style inheritance like this:
//!
//!     <!-- base.html -->
//!     This is the base.
//!     {{ body }}
//!
//!     <!-- index.html -->
//!     {{ template "base.html" }}
//!     {{ define body }}...{{ end }}
//!
//! This works because definitions are hoisted and dynamically scoped.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const Date = @import("Date.zig");
const EnumSet = std.enums.EnumSet;
const Markdown = @import("Markdown.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Template = @This();

// TODO: make templates smaller so storing by value isn't so bad.
// maybe move source, filename, offset into a *Context thing.
source: []const u8,
filename: []const u8,
offset: usize,
definitions: std.StringHashMapUnmanaged(Value) = .empty,
commands: std.ArrayList(Command) = .empty,

const Token = union(enum) {
    text: []const u8,
    expr: Expression,
    assign_var: struct { lhs: Variable, rhs: Variable },
    assign_str: struct { lhs: Variable, string: []const u8 },
    block: Variable,
    define: Variable,
    @"if": Condition,
    range: Expression,
    terminator: Terminator,
};

const Variable = []const u8;
const Expression = struct { variable: Variable, fallback: Fallback };
const Terminator = enum { eof, end, @"else" };

const Fallback = union(enum) {
    fail,
    ignore,
    string: []const u8,
    variable: Variable,
};

const Condition = union(enum) {
    truthy: Expression,
    equal: struct { expr: Expression, string: []const u8 },
    not_equal: struct { expr: Expression, string: []const u8 },
};

fn scan(scanner: *Scanner) Reporter.Error!Token {
    const braces = "{{";
    const text = scanner.consumeStopString(braces) orelse scanner.consumeRest();
    if (text.len > 0) return .{ .text = text };
    if (scanner.eof()) return .{ .terminator = .eof };
    scanner.offset += braces.len;
    scanner.skipMany(' ');
    const word = try scanIdentifier(scanner);
    scanner.skipMany(' ');
    const Kind = enum { variable, template, define, @"if", range, block, @"else", end };
    const kind = std.meta.stringToEnum(Kind, word) orelse .variable;
    const token: Token = switch (kind) {
        .variable => blk: {
            if (scanner.consume('=')) {
                scanner.skipMany(' ');
                break :blk if (scanner.peek() == '"')
                    .{ .assign_str = .{ .lhs = word, .string = try scanStringLiteral(scanner) } }
                else
                    .{ .assign_var = .{ .lhs = word, .rhs = try scanIdentifier(scanner) } };
            }
            break :blk .{ .expr = .{ .variable = word, .fallback = try scanFallback(scanner) } };
        },
        .template => .{ .expr = .{ .variable = try scanStringLiteral(scanner), .fallback = .fail } },
        .block => .{ .block = try scanIdentifier(scanner) },
        .define => .{ .define = try scanIdentifier(scanner) },
        .@"if" => .{ .@"if" = try scanCondition(scanner) },
        .range => .{ .range = try scanExpression(scanner) },
        .@"else" => .{ .terminator = .@"else" },
        .end => .{ .terminator = .end },
    };
    scanner.skipMany(' ');
    try scanner.expectString("}}");
    return token;
}

fn scanIdentifier(scanner: *Scanner) !Variable {
    const start = scanner.offset;
    if (scanner.consume('.')) return scanner.source[start..scanner.offset];
    while (scanner.peek()) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => scanner.eat(),
        else => break,
    };
    if (scanner.offset == start) return scanner.fail("expected an identifier", .{});
    return scanner.source[start..scanner.offset];
}

fn scanExpression(scanner: *Scanner) !Expression {
    const variable = try scanIdentifier(scanner);
    return Expression{ .variable = variable, .fallback = try scanFallback(scanner) };
}

fn scanFallback(scanner: *Scanner) !Fallback {
    const one = scanner.consume('?');
    const two = if (one) scanner.consume('?') else false;
    if (two or (!one and scanner.consumeMany(' ') > 0 and scanner.consumeString("??"))) {
        scanner.skipMany(' ');
        if (scanner.peek() == '"') return .{ .string = try scanStringLiteral(scanner) };
        return .{ .variable = try scanIdentifier(scanner) };
    }
    return if (one) .ignore else .fail;
}

fn scanStringLiteral(scanner: *Scanner) ![]const u8 {
    try scanner.expect('"');
    const string = scanner.consumeLineUntil('"') orelse return scanner.fail("unclosed '\"'", .{});
    return string;
}

fn scanCondition(scanner: *Scanner) !Condition {
    const expr = try scanExpression(scanner);
    scanner.skipMany(' ');
    if (scanner.consumeAny("=!")) |char| {
        try scanner.expect('=');
        scanner.skipMany(' ');
        const string = try scanStringLiteral(scanner);
        return switch (char) {
            '=' => Condition{ .equal = .{ .expr = expr, .string = string } },
            '!' => Condition{ .not_equal = .{ .expr = expr, .string = string } },
            else => unreachable,
        };
    }
    return Condition{ .truthy = expr };
}

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    const actual = try allocator.alloc(Token, expected.len);
    for (actual) |*token| token.* = try scan(&scanner);
    try testing.expectEqualDeep(expected, actual);
}

test "scan empty string" {
    try expectTokens(&[_]Token{.{ .terminator = .eof }}, "");
}

test "scan text" {
    try expectTokens(&[_]Token{ .{ .text = "foo\n" }, .{ .terminator = .eof } }, "foo\n");
}

test "scan text and variable" {
    try expectTokens(&[_]Token{
        .{ .text = "Hello " },
        .{ .expr = .{ .variable = "name", .fallback = .fail } },
        .{ .text = "!" },
        .{ .terminator = .eof },
    },
        \\Hello {{ name }}!
    );
}

test "scan everything" {
    try expectTokens(&[_]Token{
        .{ .expr = .{ .variable = "base.html", .fallback = .fail } },
        .{ .text = "\n" },
        .{ .assign_var = .{ .lhs = "ref", .rhs = "day" } },
        .{ .text = "\n" },
        .{ .assign_str = .{ .lhs = "day", .string = "Monday" } },
        .{ .text = "\n" },
        .{ .block = "foo" },
        .{ .text = "\n# Hello\n" },
        .{ .terminator = .end },
        .{ .text = "\n" },
        .{ .define = "var" },
        .{ .text = "\n    Defaults: " },
        .{ .expr = .{ .variable = "day", .fallback = .{ .string = "undefined" } } },
        .{ .text = ", " },
        .{ .expr = .{ .variable = "fake", .fallback = .{ .string = "undefined" } } },
        .{ .text = ", " },
        .{ .expr = .{ .variable = "day", .fallback = .{ .variable = "fake" } } },
        .{ .text = "\n    " },
        .{ .range = .{ .variable = "thing", .fallback = .fail } },
        .{ .text = "\n        Value: " },
        .{ .@"if" = .{ .truthy = .{ .variable = "bar", .fallback = .fail } } },
        .{ .expr = .{ .variable = ".", .fallback = .fail } },
        .{ .terminator = .@"else" },
        .{ .text = "day is " },
        .{ .expr = .{ .variable = "day", .fallback = .ignore } },
        .{ .text = " (" },
        .{ .expr = .{ .variable = "ref", .fallback = .fail } },
        .{ .text = ")" },
        .{ .terminator = .end },
        .{ .text = ",\n    " },
        .{ .terminator = .end },
        .{ .text = "\n" },
        .{ .terminator = .end },
        .{ .terminator = .eof },
    },
        \\{{ template "base.html" }}
        \\{{ ref = day }}
        \\{{ day = "Monday" }}
        \\{{ block foo }}
        \\# Hello
        \\{{ end }}
        \\{{ define var }}
        \\    Defaults: {{ day ?? "undefined" }}, {{ fake ?? "undefined"}}, {{ day ?? fake }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}day is {{day?}} ({{ref}}){{end}},
        \\    {{ end }}
        \\{{ end }}
    );
}

const Command = union(enum) {
    text: []const u8,
    expr: Expression,
    @"if": struct { cond: Condition, body: Template, else_body: ?Template },
    range: struct { expr: Expression, body: Template },
};

pub fn parse(allocator: Allocator, scanner: *Scanner) ParseError!Template {
    return parseUntil(allocator, scanner, .eof, .trim_start);
}

const Trim = enum { no_trim, trim_start };

fn parseUntil(allocator: Allocator, scanner: *Scanner, terminator: Terminator, trim: Trim) !Template {
    const terminators = EnumSet(Terminator).initOne(terminator);
    const result = try parseUntilAny(allocator, scanner, terminators, trim);
    return result.template;
}

pub const ParseError = Reporter.Error || Allocator.Error;
const ParseResult = ParseError!struct { template: Template, terminator: Terminator };

fn parseUntilAny(allocator: Allocator, scanner: *Scanner, allowed_terminators: EnumSet(Terminator), trim: Trim) ParseResult {
    var template = Template{ .source = scanner.source, .filename = scanner.filename, .offset = scanner.offset };
    const terminator: Terminator, const offset = while (true) {
        const offset = scanner.offset;
        const command: Command = switch (try scan(scanner)) {
            .terminator => |terminator| break .{ terminator, offset },
            .assign_var => |assign_var| {
                template.trimLastIfText();
                if (mem.eql(u8, assign_var.rhs, "."))
                    return scanner.fail("assignment to `.` is not allowed", .{});
                try template.definitions.put(allocator, assign_var.lhs, Value{ .reference = .{ .variable = assign_var.rhs, .source = scanner.source, .filename = scanner.filename } });
                continue;
            },
            .assign_str => |assign_str| {
                template.trimLastIfText();
                try template.definitions.put(allocator, assign_str.lhs, Value{ .string = assign_str.string });
                continue;
            },
            .block => |variable| {
                template.trimLastIfText();
                const body = try parseUntil(allocator, scanner, .end, .trim_start);
                if (!(body.definitions.count() == 0 and body.commands.items.len == 1 and body.commands.items[0] == .text))
                    return scanner.failAtOffset(offset, "template commands are not allowed in markdown blocks", .{});
                const text = body.commands.items[0].text;
                // TODO this pattern comes up several times of doing ptr offset in buffer... maybe add ctor for it
                const text_offset = text.ptr - body.source.ptr;
                var text_scanner = Scanner{
                    .source = body.source[0 .. text_offset + text.len],
                    .reporter = scanner.reporter,
                    .filename = body.filename,
                    .offset = text_offset,
                };
                const markdown = try Markdown.parse(allocator, &text_scanner);
                const options = Markdown.Options{ .auto_heading_ids = true, .highlight_code = true };
                try template.definitions.put(allocator, variable, Value{ .markdown = .{ .markdown = markdown, .options = options } });
                continue;
            },
            .define => |variable| {
                template.trimLastIfText();
                const body = try parseUntil(allocator, scanner, .end, .trim_start);
                try template.definitions.put(allocator, variable, Value{ .template = body });
                continue;
            },
            .text => |text| blk: {
                if (trim == .trim_start and template.commands.items.len == 0) {
                    const trimmed = trimStart(text);
                    if (trimmed.len == 0) continue;
                    break :blk .{ .text = trimmed };
                }
                break :blk .{ .text = text };
            },
            .expr => |expr| .{ .expr = expr },
            .@"if" => |cond| blk: {
                template.trimLastIfText();
                const end_or_else = EnumSet(Terminator).init(.{ .end = true, .@"else" = true });
                const result = try parseUntilAny(allocator, scanner, end_or_else, .no_trim);
                break :blk .{
                    .@"if" = .{
                        .cond = cond,
                        .body = result.template,
                        .else_body = switch (result.terminator) {
                            .@"else" => try parseUntil(allocator, scanner, .end, .no_trim),
                            else => null,
                        },
                    },
                };
            },
            .range => |expr| blk: {
                template.trimLastIfText();
                break :blk .{
                    .range = .{
                        .expr = expr,
                        .body = try parseUntil(allocator, scanner, .end, .no_trim),
                    },
                };
            },
        };
        try template.commands.append(allocator, command);
    };
    template.trimLastIfText();
    if (!allowed_terminators.contains(terminator)) {
        return scanner.failAtOffset(offset, "unexpected {s}", .{
            switch (terminator) {
                .end => "{{ end }}",
                .@"else" => "{{ else }}",
                .eof => "EOF",
            },
        });
    }
    return .{ .template = template, .terminator = terminator };
}

fn trimLastIfText(template: *Template) void {
    if (template.commands.items.len == 0) return;
    switch (template.commands.items[template.commands.items.len - 1]) {
        .text => |*text| {
            const trimmed = trimEnd(text.*);
            if (trimmed.len > 0) text.* = trimmed else _ = template.commands.pop();
        },
        else => {},
    }
}

const whitespace_chars = " \t\n";

fn trimStart(text: []const u8) []const u8 {
    return mem.trimStart(u8, text, whitespace_chars);
}

fn trimEnd(text: []const u8) []const u8 {
    const index = mem.findScalarLast(u8, text, '\n') orelse return text;
    if (mem.findNonePos(u8, text, index + 1, whitespace_chars)) |_| return text;
    return mem.trimEnd(u8, text[0..index], whitespace_chars);
}

fn expectParse(allocator: Allocator, source: []const u8) !Template {
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    return parse(allocator, &scanner);
}

fn expectParseFailure(expected_message: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, parse(allocator, &scanner));
}

test "parse text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "foo";
    const template = try expectParse(allocator, source);
    try testing.expectEqual(@as(usize, 0), template.definitions.count());
    try testing.expectEqualSlices(Command, &.{Command{ .text = source }}, template.commands.items);
}

test "parse everything" {
    const source =
        \\{{ template "base.html" }}
        \\{{ day = "Monday" }}
        \\{{ block foo }}
        \\# Hello
        \\{{ end }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}day is {{day?}}{{end}},
        \\    {{ end }}
        \\{{ end }}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const template = try expectParse(arena.allocator(), source);

    try testing.expectEqualStrings("<input>", template.filename);
    try testing.expectEqual(@as(usize, 0), template.offset);

    const definitions = template.definitions;
    try testing.expectEqual(@as(usize, 3), definitions.count());
    const define_day = definitions.get("day").?.string;
    try testing.expectEqualStrings("Monday", define_day);
    const define_foo = definitions.get("foo").?.markdown.markdown;
    try testing.expectEqualStrings("# Hello", define_foo.text);
    try testing.expectEqualStrings("<input>", define_foo.context.filename);
    try testing.expectEqual(source[0..71], define_foo.context.source);
    try testing.expectEqual(@as(usize, 0), define_foo.context.links.count());
    const define_var = definitions.get("var").?.template;
    try testing.expectEqual(@as(usize, 0), define_var.definitions.count());
    try testing.expectEqualStrings("<input>", define_var.filename);
    try testing.expectEqual(@as(usize, 98), define_var.offset);
    const var_body = define_var.commands.items;
    try testing.expectEqual(@as(usize, 1), var_body.len);
    const range_thing = var_body[0].range;
    try testing.expectEqualStrings("thing", range_thing.expr.variable);
    try testing.expectEqual(Fallback.fail, range_thing.expr.fallback);
    try testing.expectEqual(@as(usize, 0), range_thing.body.definitions.count());
    const range_body = range_thing.body.commands.items;
    try testing.expectEqual(@as(usize, 3), range_body.len);
    try testing.expectEqualStrings("\n        Value: ", range_body[0].text);
    const if_bar = range_body[1].@"if";
    try testing.expectEqualStrings(",", range_body[2].text);
    try testing.expectEqual(@as(usize, 0), if_bar.body.definitions.count());
    try testing.expectEqual(@as(usize, 0), if_bar.else_body.?.definitions.count());
    const if_body = if_bar.body.commands.items;
    try testing.expectEqual(@as(usize, 1), if_body.len);
    try testing.expectEqualStrings(".", if_body[0].expr.variable);
    try testing.expectEqual(Fallback.fail, if_body[0].expr.fallback);
    const else_body = if_bar.else_body.?.commands.items;
    try testing.expectEqual(@as(usize, 2), else_body.len);
    try testing.expectEqualStrings("day is ", else_body[0].text);
    try testing.expectEqualStrings("day", else_body[1].expr.variable);
    try testing.expectEqual(Fallback.ignore, else_body[1].expr.fallback);

    const commands = template.commands.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("base.html", commands[0].expr.variable);
    try testing.expectEqual(Fallback.fail, commands[0].expr.fallback);
}

test "parse multiple definitions" {
    const source =
        \\{{ define a }}1{{ end }}
        \\{{ define b }}2{{ end }}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const template = try expectParse(arena.allocator(), source);
    try testing.expectEqualSlices(Command, &.{}, template.commands.items);
    try testing.expectEqual(@as(usize, 2), template.definitions.count());
    const def_a = template.definitions.get("a").?.template;
    try testing.expectEqual(@as(usize, 1), def_a.commands.items.len);
    try testing.expectEqualStrings("1", def_a.commands.items[0].text);
    const def_b = template.definitions.get("b").?.template;
    try testing.expectEqual(@as(usize, 1), def_b.commands.items.len);
    try testing.expectEqualStrings("2", def_b.commands.items[0].text);
}

test "invalid command" {
    try expectParseFailure(
        \\<input>:1:26: expected "}}", got "ba"
    ,
        \\Too many words in {{ foo bar qux }}.
    );
}

test "invalid dot" {
    try expectParseFailure(
        \\<input>:2:12: expected "}}", got ".h"
    ,
        \\Good {{ template "base.html" }}
        \\Bad {{ base.html }}
    );
}

test "unterminated command" {
    try expectParseFailure(
        \\<input>:1:26: expected "}}", got EOF
    ,
        \\Missing closing {{ braces
    );
}

test "missing end" {
    try expectParseFailure(
        \\<input>:1:40: unexpected EOF
    ,
        \\It's not terminated! {{ if foo }} oops.
    );
}

test "unexpected end" {
    try expectParseFailure(
        \\<input>:2:1: unexpected {{ end }}
    ,
        \\Hello {{ if logged_in }}{{ username}}{{ else }}Anonymous{{ end }}
        \\{{ end }}
    );
}

test "unexpected else" {
    try expectParseFailure(
        \\<input>:1:17: unexpected {{ else }}
    ,
        \\{{ range . }}foo{{ else }}bar{{ end }}
    );
}

test "missing assignment right-hand side" {
    try expectParseFailure(
        \\<input>:1:8: expected an identifier
    ,
        \\{{ a = }}
    );
}

test "invalid reference to dot" {
    try expectParseFailure(
        \\<input>:1:12: assignment to `.` is not allowed
    ,
        \\{{ y = . }}
    );
}

pub const Value = union(enum) {
    null,
    bool: bool,
    string: []const u8,
    array: std.ArrayList(Value),
    dict: std.StringHashMapUnmanaged(Value),
    pointer: *const Value,
    reference: struct { variable: Variable, source: []const u8, filename: []const u8 },
    template: Template,
    date: struct { date: Date, style: Date.Style },
    markdown: struct { markdown: Markdown, options: Markdown.Options },

    pub fn init(allocator: Allocator, object: anytype) !Value {
        return switch (@typeInfo(@TypeOf(object))) {
            .optional => if (object) |obj| initNonOptional(allocator, obj) else .null,
            else => initNonOptional(allocator, object),
        };
    }

    fn initNonOptional(allocator: Allocator, object: anytype) !Value {
        const Type = @TypeOf(object);
        switch (Type) {
            Value => return object,
            @TypeOf(null) => return .null,
            bool => return .{ .bool = object },
            Template => return .{ .template = object },
            else => {},
        }
        switch (@typeInfo(Type)) {
            .array => |array_type| return initArray(allocator, object, array_type.child),
            .pointer => |pointer_type| return if (pointer_type.size == .slice)
                initArray(allocator, object, pointer_type.child)
            else if (pointer_type.child == Value)
                .{ .pointer = object }
            else switch (@typeInfo(pointer_type.child)) {
                .array => |array_type| initArray(allocator, object, array_type.child),
                else => @compileError("invalid pointer type: " ++ @typeName(Type)),
            },
            .@"struct" => |struct_type| if (struct_type.is_tuple) {
                var array: std.ArrayList(Value) = .empty;
                inline for (object) |item| try array.append(allocator, try init(allocator, item));
                return .{ .array = array };
            } else {
                var dict: std.StringHashMapUnmanaged(Value) = .empty;
                inline for (struct_type.fields) |field| {
                    const field_value = try init(allocator, @field(object, field.name));
                    try dict.put(allocator, field.name, field_value);
                }
                return .{ .dict = dict };
            },
            else => @compileError("invalid type: " ++ @typeName(Type)),
        }
    }

    fn initArray(allocator: Allocator, object: anytype, comptime ItemType: type) !Value {
        if (ItemType == u8) return .{ .string = object };
        const info = @typeInfo(@TypeOf(object));
        if (ItemType == Value and info == .pointer and !info.pointer.is_const)
            return .{ .array = std.ArrayList(Value).fromOwnedSlice(object) };
        var array: std.ArrayList(Value) = .empty;
        for (object) |item| try array.append(allocator, try init(allocator, item));
        return .{ .array = array };
    }

    fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |bool_val| bool_val,
            .string => |string| string.len > 0,
            .array => |array| array.items.len > 0,
            .dict, .template, .date, .markdown => true,
            .pointer, .reference => unreachable,
        };
    }
};

test "value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var bool_array_1 = [2]bool{ true, false };
    var bool_array_2 = [2]bool{ true, false };
    var value_1 = Value{ .bool = false };
    var value_array_1 = [1]Value{.{ .bool = false }};
    var value_array_2 = [1]Value{.{ .bool = false }};
    _ = try Value.init(arena.allocator(), .{
        .null = null,
        .true = true,
        .false = false,
        .string = "hello",
        .empty = .{},
        .tuple = .{ true, "hello" },
        .array = [2]bool{ true, false },
        .array_ptr = @as(*const [2]bool, &[2]bool{ true, false }),
        .slice = @as([]const bool, &[2]bool{ true, false }),
        .array_ptr_mut = @as(*[2]bool, &bool_array_1),
        .slice_mut = @as([]bool, &bool_array_2),
        .nested = .{ .true = true, .string = "hello" },
        .value = try Value.init(arena.allocator(), "hello"),
        .value_ptr = @as(*const Value, &Value{ .bool = false }),
        .value_ptr_mut = @as(*Value, &value_1),
        .value_ref = Value{ .reference = .{ .variable = "x", .source = " x ", .filename = "<input>" } },
        .value_tuple = .{Value{ .bool = false }},
        .value_array = [1]Value{.{ .bool = false }},
        .value_array_ptr = @as(*const [1]Value, &[1]Value{.{ .bool = false }}),
        .value_slice = @as([]const Value, &[1]Value{.{ .bool = false }}),
        .value_array_ptr_mut = @as(*[1]Value, &value_array_1),
        .value_slice_mut = @as([]Value, &value_array_2),
        .template = try expectParse(arena.allocator(), "template"),
    });
}

pub fn execute(self: *const Template, allocator: Allocator, reporter: *Reporter, writer: anytype, hooks: anytype, scope: Scope) !void {
    const ctx = ExecuteContext(@TypeOf(writer), @TypeOf(hooks)){
        .allocator = allocator,
        .reporter = reporter,
        .writer = writer,
        .hooks = hooks,
    };
    return self.exec(ctx, scope);
}

fn ExecuteContext(comptime Writer: type, comptime Hooks: type) type {
    return struct { allocator: Allocator, reporter: *Reporter, writer: Writer, hooks: Hooks };
}

pub const Scope = struct {
    parent: ?*const Scope,
    value: Value,

    pub fn init(value: Value) Scope {
        assert(value != .pointer);
        return Scope{ .parent = null, .value = value };
    }

    pub fn initChild(self: *const Scope, value: Value) Scope {
        assert(value != .pointer);
        return Scope{ .parent = self, .value = value };
    }

    fn lookup(self: *const Scope, variable: Variable) ?Value {
        if (mem.eql(u8, variable, ".")) return self.value;
        switch (self.value) {
            .dict => |dict| if (dict.get(variable)) |value| return value,
            else => {},
        }
        if (self.parent) |parent| return parent.lookup(variable);
        return null;
    }
};

fn chase(self: *const Template, ctx: anytype, scope: Scope, variable: Variable, value: Value) !Value {
    const pointee = switch (value) {
        .pointer => |ptr| ptr.*,
        .reference => |ref| scope.lookup(ref.variable) orelse {
            const err = ctx.reporter.fail(
                self.filename,
                Location.fromPtr(self.source, variable.ptr),
                "{s}: referenced variable `{s}` not found",
                .{ variable, ref.variable },
            );
            ctx.reporter.addNote(
                ref.filename,
                Location.fromPtr(ref.source, ref.variable.ptr),
                "`{s}` was assigned to `{s}` here",
                .{ variable, ref.variable },
            );
            return err;
        },
        else => value,
    };
    return switch (pointee) {
        .pointer, .reference => ctx.reporter.fail(
            self.filename,
            Location.fromPtr(self.source, variable.ptr),
            "{s}: {t} to {t} not allowed",
            .{ variable, value, pointee },
        ),
        else => pointee,
    };
}

fn lookup(self: *const Template, ctx: anytype, scope: Scope, expr: Expression) !?Value {
    const value = scope.lookup(expr.variable) orelse return switch (expr.fallback) {
        .ignore => null,
        .fail => ctx.reporter.fail(
            self.filename,
            Location.fromPtr(self.source, expr.variable.ptr),
            "{s}: variable not found",
            .{expr.variable},
        ),
        .string => |string| Value{ .string = string },
        .variable => |variable| self.lookup(ctx, scope, Expression{ .variable = variable, .fallback = .fail }),
    };
    return try self.chase(ctx, scope, expr.variable, value);
}

fn exec(self: *const Template, ctx: anytype, parent: Scope) !void {
    const scope = if (self.definitions.count() == 0) parent else parent.initChild(Value{ .dict = self.definitions });
    for (self.commands.items) |command| switch (command) {
        .text => |text| try ctx.writer.writeAll(text),
        .expr => |expr| switch (try self.lookup(ctx, scope, expr) orelse continue) {
            .string => |string| try ctx.writer.writeAll(string),
            .template => |template| template.exec(ctx, scope) catch |err| {
                if (err == error.ErrorWasReported) {
                    ctx.reporter.addNote(template.filename, Location.fromOffset(template.source, template.offset), "`{s}` defined here", .{expr.variable});
                    ctx.reporter.addNote(self.filename, Location.fromPtr(self.source, expr.variable.ptr), "`{s}` referenced here", .{expr.variable});
                }
                return err;
            },
            .date => |args| try args.date.render(ctx.writer, args.style),
            .markdown => |args| try args.markdown.render(ctx.reporter, ctx.writer, ctx.hooks, args.options),
            .pointer, .reference => unreachable,
            else => |value| return ctx.reporter.fail(
                self.filename,
                Location.fromPtr(self.source, expr.variable.ptr),
                "{s}: cannot render variable of type {t}",
                .{ expr.variable, value },
            ),
        },
        .@"if" => |if_cmd| {
            const expr = switch (if_cmd.cond) {
                .truthy => |expr| expr,
                inline .equal, .not_equal => |cond| cond.expr,
            };
            const value = try self.lookup(ctx, scope, expr) orelse Value{ .bool = false };
            const is_true = switch (if_cmd.cond) {
                .truthy => value.truthy(),
                .equal => |equal| switch (value) {
                    .string => |string| mem.eql(u8, string, equal.string),
                    else => false,
                },
                .not_equal => |not_equal| switch (value) {
                    .string => |string| !mem.eql(u8, string, not_equal.string),
                    else => true,
                },
            };
            if (is_true)
                try if_cmd.body.exec(ctx, scope.initChild(value))
            else if (if_cmd.else_body) |body|
                try body.exec(ctx, scope);
        },
        .range => |range| switch (try self.lookup(ctx, scope, range.expr) orelse continue) {
            .null => {},
            .array => |array| for (array.items) |item| try range.body.exec(ctx, scope.initChild(try self.chase(ctx, scope, range.expr.variable, item))),
            .pointer, .reference => unreachable,
            else => |value| return ctx.reporter.fail(
                self.filename,
                Location.fromPtr(self.source, range.expr.variable.ptr),
                "{s}: cannot range over variable of type {t}",
                .{ range.expr.variable, value },
            ),
        },
    };
}

fn expectExecute(expected: []const u8, source: []const u8, object: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var template = try parse(allocator, &scanner);
    const scope = Scope.init(try Value.init(allocator, object));
    var actual: std.Io.Writer.Allocating = .init(allocator);
    try template.execute(allocator, &reporter, &actual.writer, .{}, scope);
    try testing.expectEqualStrings(expected, actual.written());
}

fn expectExecuteFailure(expected_message: []const u8, source: []const u8, object: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var template = try parse(allocator, &scanner);
    const scope = Scope.init(try Value.init(allocator, object));
    var actual: std.Io.Writer.Allocating = .init(allocator);
    try reporter.expectFailure(
        expected_message,
        template.execute(allocator, &reporter, &actual.writer, .{}, scope),
    );
}

test "execute text" {
    try expectExecute("", "", .{});
    try expectExecute("Hello world!", "Hello world!", .{});
}

test "execute variable" {
    try expectExecute("foo", "{{ . }}", "foo");
    try expectExecute("foo bar", "{{ x }} {{ y }}", .{ .x = "foo", .y = "bar" });
}

test "execute optional variable" {
    try expectExecute("foo ", "{{ x? }} {{ y? }}", .{ .x = "foo" });
}

test "execute fallback variable" {
    try expectExecute("foo", "{{ x ?? y }}", .{ .x = "foo", .y = "bar" });
    try expectExecute("", "{{ x ?? y }}", .{ .x = "", .y = "bar" });
    try expectExecute("bar", "{{ x ?? y }}", .{ .y = "bar" });
}

test "execute shadowing" {
    try expectExecute("aba", "{{ x }}{{ if y }}{{ x }}{{ end }}{{ x }}", .{ .x = "a", .y = .{ .x = "b" } });
    try expectExecute("aaa", "{{ x }}{{ if y }}{{ x }}{{ end }}{{ x }}", .{ .x = "a", .y = .{ .z = "b" } });
}

test "execute reference" {
    try expectExecute("foo", "{{ y = x }}{{ y }}", .{ .x = "foo" });
}

test "execute definition" {
    try expectExecute("foo", "{{ define x }}foo{{ end }}{{ x }}", .{});
    try expectExecute("foo", "{{ define x }}foo{{ end }}{{ x }}", .{ .x = "bar" });
}

test "execute multiple definitions" {
    try expectExecute("foobar", "{{ define x }}foo{{ end }}{{ define y }}bar{{ end }}{{ x }}{{ y }}", .{});
}

test "execute dependent definitions" {
    try expectExecute("barbar", "{{ define x }}{{ y }}{{ end }}{{ define y }}bar{{ end }}{{ x }}{{ y }}", .{});
}

test "execute if" {
    try expectExecute("yes", "{{ if val }}yes{{ end }}", .{ .val = true });
    try expectExecute("", "{{ if val }}yes{{ end }}", .{ .val = false });
}

test "execute if-else bool" {
    try expectExecute("yes", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = true });
    try expectExecute("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = false });
}

test "execute if-else string" {
    try expectExecute("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = "" });
    try expectExecute("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = @as(?[]const u8, "") });
    try expectExecute("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = @as(?[]const u8, null) });
}

test "execute if equal string" {
    try expectExecute("yes", "{{ if val == \"foo\" }}yes{{ end }}", .{ .val = "foo" });
    try expectExecute("", "{{ if val == \"foo\" }}yes{{ end }}", .{ .val = "bar" });
    try expectExecute("", "{{ if val == \"foo\" }}yes{{ end }}", .{ .val = null });
    try expectExecute("", "{{ if val? == \"foo\" }}yes{{ end }}", .{});
}

test "execute if not equal string" {
    try expectExecute("", "{{ if val != \"foo\" }}yes{{ end }}", .{ .val = "foo" });
    try expectExecute("yes", "{{ if val != \"foo\" }}yes{{ end }}", .{ .val = "bar" });
    try expectExecute("yes", "{{ if val != \"foo\" }}yes{{ end }}", .{ .val = null });
    try expectExecute("yes", "{{ if val? != \"foo\" }}yes{{ end }}", .{});
}

test "execute range" {
    try expectExecute("Alice,Bob,", "{{ range . }}{{ . }},{{ end }}", .{ "Alice", "Bob" });
}

test "execute range of reference" {
    try expectExecute("Alice,Bob,", "{{ list = x }}{{ range list }}{{ . }},{{ end }}", .{ .x = .{ "Alice", "Bob" } });
}

test "execute not a string" {
    try expectExecuteFailure("<input>:1:4: .: cannot render variable of type array", "{{ . }}", .{});
}

test "execute variable not found" {
    try expectExecuteFailure("<input>:1:10: foo: variable not found", "Hello {{ foo }}!", .{});
}

test "execute fallback variable not found" {
    try expectExecuteFailure("<input>:1:9: y: variable not found", "{{ x ?? y }}!", .{});
}

test "execute double pointer" {
    try expectExecuteFailure("<input>:1:10: foo: pointer to pointer not allowed", "Hello {{ foo }}!", .{ .foo = &Value{ .pointer = &Value{ .string = "bar" } } });
}

test "execute double pointer in scope" {
    try expectExecuteFailure("<input>:1:7: foo: pointer to pointer not allowed", "{{ if foo }}{{ end }}", .{ .foo = &Value{ .pointer = &Value{ .string = "bar" } } });
}

test "execute double pointer in array" {
    try expectExecuteFailure("<input>:1:10: .: pointer to pointer not allowed", "{{ range . }}{{ end }}", .{&Value{ .pointer = &Value{ .string = "bar" } }});
}

test "execute invalid reference" {
    try expectExecuteFailure(
        \\<input>:1:4: ref: referenced variable `val` not found
        \\<input>:1:19: note: `ref` was assigned to `val` here
    , "{{ ref }}{{ ref = val }}", .{});
}

test "execute everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectExecute(
        \\foo is:
        \\<h1 id="hello">Hello</h1>
        \\var is:
        \\Defaults: Monday, undefined, Monday
        \\        Value: inner bar,
        \\        Value: day is Monday (Monday),
    ,
        \\{{ template "base.html" }}
        \\{{ ref = day }}
        \\{{ day = "Monday" }}
        \\{{ block foo }}
        \\# Hello
        \\{{ end }}
        \\{{ define var }}
        \\    Defaults: {{ day ?? "undefined" }}, {{ fake ?? "undefined"}}, {{ day ?? fake }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}day is {{day?}} ({{ref}}){{end}},
        \\    {{ end }}
        \\{{ end }}
    ,
        .{
            .bar = false,
            .thing = .{ .{ .bar = "inner bar" }, "foo" },
            .@"base.html" = try expectParse(arena.allocator(), "foo is:\n{{ foo }}\nvar is:\n{{ var }}"),
        },
    );
}
