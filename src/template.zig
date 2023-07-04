// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const fmtEscapes = std.zig.fmtEscapes;
const Allocator = mem.Allocator;
const Date = @import("Date.zig");
const EnumSet = std.enums.EnumSet;
const markdown = @import("markdown.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;
const Template = @This();

filename: []const u8,
definitions: std.ArrayListUnmanaged(Definition) = .{},
commands: std.ArrayListUnmanaged(Command) = .{},

const Variable = []const u8;

const Token = struct {
    value: TokenValue,
    location: Location,
};

const TokenValue = union(enum) {
    text: []const u8,
    include: []const u8, // template path
    variable: Variable,
    define: Variable,
    start: Variable, // "if" or "range"
    @"else",
    end,
};

fn scan(scanner: *Scanner) Reporter.Error!?Token {
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

fn expectTokens(expected: []const TokenValue, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual = std.ArrayList(TokenValue).init(allocator);
    while (try scan(&scanner)) |token| try actual.append(token.value);
    try testing.expectEqualDeep(expected, actual.items);
}

test "scan empty string" {
    try expectTokens(&[_]TokenValue{}, "");
}

test "scan text" {
    try expectTokens(&[_]TokenValue{.{ .text = "foo\n" }}, "foo\n");
}

test "scan text and variable" {
    try expectTokens(&[_]TokenValue{
        .{ .text = "Hello " },
        .{ .variable = "name" },
        .{ .text = "!" },
    },
        \\Hello {{ name }}!
    );
}

test "scan everything" {
    try expectTokens(&[_]TokenValue{
        .{ .include = "base.html" },
        .{ .text = "\n" },
        .{ .define = "var" },
        .{ .text = "\n    " },
        .{ .start = "thing" },
        .{ .text = "\n        Value: " },
        .{ .start = "bar" },
        .{ .variable = "." },
        .@"else",
        .{ .text = "Fallback" },
        .end,
        .{ .text = ",\n    " },
        .end,
        .{ .text = "\n" },
        .end,
    },
        \\{{ include "base.html" }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}Fallback{{end}},
        \\    {{ end }}
        \\{{ end }}
    );
}

const Definition = struct {
    variable: Variable,
    body: Template,
};

const Command = struct {
    value: CommandValue,
    location: Location,
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

pub fn parse(
    allocator: Allocator,
    scanner: *Scanner,
    include_map: std.StringHashMap(Template),
) ParseError!Template {
    const ctx = ParseContext{ .allocator = allocator, .scanner = scanner, .include_map = include_map };
    return parseUntil(ctx, .eof, .trim_start);
}

const ParseContext = struct {
    allocator: Allocator,
    scanner: *Scanner,
    include_map: std.StringHashMap(Template),
};

const Trim = enum { no_trim, trim_start };

fn parseUntil(ctx: ParseContext, terminator: Terminator, trim: Trim) !Template {
    const terminators = EnumSet(Terminator).initOne(terminator);
    const result = try parseUntilAny(ctx, terminators, trim);
    return result.template;
}

const Terminator = enum { end, @"else", eof };
const ParseError = Reporter.Error || Allocator.Error;
const ParseResult = ParseError!struct { template: Template, terminator: Terminator };

fn parseUntilAny(ctx: ParseContext, allowed_terminators: EnumSet(Terminator), trim: Trim) ParseResult {
    const scanner = ctx.scanner;
    var template = Template{ .filename = scanner.filename };
    var terminator = Terminator.eof;
    var terminator_pos: ?Location = null;
    while (try scan(scanner)) |token| {
        const command_value: CommandValue = switch (token.value) {
            .define => |variable| {
                template.trimLastIfText();
                try template.definitions.append(ctx.allocator, Definition{
                    .variable = variable,
                    .body = try parseUntil(ctx, .end, .trim_start),
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
            .text => |text| blk: {
                if (trim == .trim_start and template.commands.items.len == 0) {
                    const trimmed = trimStart(text);
                    if (trimmed.len == 0) continue;
                    break :blk .{ .text = trimmed };
                }
                break :blk .{ .text = text };
            },
            .variable => |variable| .{ .variable = variable },
            .include => |path| .{
                .include = ctx.include_map.getPtr(path) orelse
                    return scanner.failAt(token.location, "{s}: template not found", .{path}),
            },
            .start => |variable| blk: {
                template.trimLastIfText();
                const end_or_else = EnumSet(Terminator).init(.{ .end = true, .@"else" = true });
                const result = try parseUntilAny(ctx, end_or_else, .no_trim);
                break :blk .{
                    .control = .{
                        .variable = variable,
                        .body = result.template,
                        .else_body = switch (result.terminator) {
                            .@"else" => try parseUntil(ctx, .end, .no_trim),
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
    template.trimLastIfText();
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

fn trimLastIfText(template: *Template) void {
    if (template.commands.items.len == 0) return;
    switch (template.commands.items[template.commands.items.len - 1].value) {
        .text => |*text| {
            const trimmed = trimEnd(text.*);
            if (trimmed.len > 0) text.* = trimmed else _ = template.commands.pop();
        },
        else => {},
    }
}

const whitespace_chars = " \t\n";

fn trimStart(text: []const u8) []const u8 {
    return mem.trimLeft(u8, text, whitespace_chars);
}

fn trimEnd(text: []const u8) []const u8 {
    const index = mem.lastIndexOfScalar(u8, text, '\n') orelse return text;
    if (mem.indexOfNonePos(u8, text, index + 1, whitespace_chars)) |_| return text;
    return mem.trimRight(u8, text[0..index], whitespace_chars);
}

fn expectParseSuccess(allocator: Allocator, source: []const u8, include_map: std.StringHashMap(Template)) !Template {
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    return parse(allocator, &scanner, include_map);
}

fn expectParseFailure(expected_message: []const u8, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var include_map = std.StringHashMap(Template).init(allocator);
    try reporter.expectFailure(expected_message, parse(allocator, &scanner, include_map));
}

test "parse text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "foo";
    var include_map = std.StringHashMap(Template).init(allocator);
    var template = try expectParseSuccess(allocator, source, include_map);
    try testing.expectEqualSlices(Definition, &.{}, template.definitions.items);
    try testing.expectEqualSlices(Command, &[_]Command{
        .{
            .value = .{ .text = source },
            .location = .{ .line = 1, .column = 1 },
        },
    }, template.commands.items);
}

test "parse everything" {
    const source =
        \\{{ include "base.html" }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}Fallback{{end}},
        \\    {{ end }}
        \\{{ end }}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var include_map = std.StringHashMap(Template).init(allocator);
    try include_map.put("base.html", undefined);
    const base_template: *const Template = include_map.getPtr("base.html").?;
    var template = try expectParseSuccess(allocator, source, include_map);

    const definitions = template.definitions.items;
    try testing.expectEqual(@as(usize, 1), definitions.len);
    const define_var = definitions[0];
    try testing.expectEqualStrings("var", define_var.variable);
    try testing.expectEqual(@as(usize, 0), define_var.body.definitions.items.len);
    const var_body = define_var.body.commands.items;
    try testing.expectEqual(@as(usize, 1), var_body.len);
    const range_thing = var_body[0].value.control;
    try testing.expectEqualStrings("thing", range_thing.variable);
    try testing.expectEqual(@as(usize, 0), range_thing.body.definitions.items.len);
    const range_body = range_thing.body.commands.items;
    try testing.expectEqual(@as(usize, 3), range_body.len);
    try testing.expectEqual(@as(?Template, null), range_thing.else_body);
    try testing.expectEqualStrings("\n        Value: ", range_body[0].value.text);
    const if_bar = range_body[1].value.control;
    try testing.expectEqualStrings(",", range_body[2].value.text);
    try testing.expectEqual(@as(usize, 0), if_bar.body.definitions.items.len);
    try testing.expectEqual(@as(usize, 0), if_bar.else_body.?.definitions.items.len);
    const if_body = if_bar.body.commands.items;
    try testing.expectEqual(@as(usize, 1), if_body.len);
    try testing.expectEqualStrings(".", if_body[0].value.variable);
    const else_body = if_bar.else_body.?.commands.items;
    try testing.expectEqual(@as(usize, 1), else_body.len);
    try testing.expectEqualStrings("Fallback", else_body[0].value.text);

    const commands = template.commands.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqual(base_template, commands[0].value.include);
}

test "invalid command" {
    try expectParseFailure(
        \\<input>:1:26: expected "}}", got "ba"
    ,
        \\Too many words in {{ foo bar qux }}.
    );
}

test "unterminated command" {
    try expectParseFailure(
        \\<input>:1:27: unexpected EOF, expected "}}"
    ,
        \\Missing closing {{ braces.
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

test "invalid include" {
    try expectParseFailure(
        \\<input>:2:1: does_not_exist: template not found
    ,
        \\Some text before.
        \\{{ include "does_not_exist" }}
    );
}

pub const Value = union(enum) {
    string: ?[]const u8,
    bool: bool,
    array: std.ArrayListUnmanaged(Value),
    dict: std.StringHashMapUnmanaged(Value),
    date: struct { date: Date, style: Date.Style },
    markdown: struct { span: Span, filename: []const u8, options: markdown.Options },
    template: *const Template,

    pub fn init(allocator: Allocator, object: anytype) !Value {
        comptime var Type = @TypeOf(object);
        if (Type == Value) return object;
        switch (@typeInfo(Type)) {
            .Bool => return .{ .bool = object },
            .Optional => |Optional| Type = Optional.child,
            else => {},
        }
        if (comptime std.meta.trait.isZigString(Type))
            return .{ .string = object };
        if (comptime std.meta.trait.isTuple(Type)) {
            var array = std.ArrayListUnmanaged(Value){};
            inline for (object) |item| try array.append(allocator, try init(allocator, item));
            return .{ .array = array };
        }
        if (comptime std.meta.trait.isIndexable(Type)) {
            var array = std.ArrayListUnmanaged(Value){};
            for (object) |item| try array.append(allocator, try init(allocator, item));
            return .{ .array = array };
        }
        switch (@typeInfo(Type)) {
            .Struct => |the_struct| {
                var dict = std.StringHashMapUnmanaged(Value){};
                inline for (the_struct.fields) |field| {
                    const field_value = try init(allocator, @field(object, field.name));
                    try dict.put(allocator, field.name, field_value);
                }
                return .{ .dict = dict };
            },
            else => @compileError("invalid type: " ++ @typeName(Type)),
        }
    }
};

test "value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try Value.init(arena.allocator(), .{
        .true = true,
        .false = false,
        .string = "hello",
        .empty = .{},
        .array = .{ true, "hello" },
        .slice = &[_]bool{ true, false },
        .nested = .{ .true = true, .string = "hello" },
        .value = try Value.init(arena.allocator(), "hello"),
    });
}

pub fn execute(
    self: Template,
    allocator: Allocator,
    reporter: *Reporter,
    writer: anytype,
    scope: *Scope,
) !void {
    const ctx = ExecuteContext(@TypeOf(writer)){ .allocator = allocator, .reporter = reporter, .writer = writer };
    return self.exec(ctx, scope);
}

fn ExecuteContext(comptime Writer: type) type {
    return struct { allocator: Allocator, reporter: *Reporter, writer: Writer };
}

pub const Scope = struct {
    parent: ?*const Scope,
    value: Value,
    definitions: std.StringHashMapUnmanaged(*const Template),

    pub fn init(value: Value) Scope {
        return Scope{ .parent = null, .value = value, .definitions = .{} };
    }

    pub fn initChild(self: *const Scope, value: Value) Scope {
        return Scope{ .parent = self, .value = value, .definitions = .{} };
    }

    fn reset(self: *Scope, value: Value) *Scope {
        self.definitions.clearRetainingCapacity();
        self.value = value;
        return self;
    }

    fn lookup(self: *const Scope, variable: Variable) ?Value {
        if (mem.eql(u8, variable, ".")) return self.value;
        if (self.definitions.get(variable)) |template| return Value{ .template = template };
        switch (self.value) {
            .dict => |dict| if (dict.get(variable)) |value| return value,
            else => {},
        }
        if (self.parent) |parent| return parent.lookup(variable);
        return null;
    }
};

fn lookup(self: Template, ctx: anytype, scope: *const Scope, command: Command, variable: Variable) !Value {
    return scope.lookup(variable) orelse
        ctx.reporter.failAt(self.filename, command.location, "{s}: variable not found", .{variable});
}

fn exec(self: Template, ctx: anytype, scope: *Scope) !void {
    for (self.definitions.items) |definition|
        try scope.definitions.put(ctx.allocator, definition.variable, &definition.body);
    for (self.commands.items) |command| switch (command.value) {
        .text => |text| try ctx.writer.writeAll(text),
        .include => |template| try template.exec(ctx, scope),
        .variable => |variable| switch (try self.lookup(ctx, scope, command, variable)) {
            .string => |optional| if (optional) |string| try ctx.writer.writeAll(string),
            .date => |args| try args.date.render(args.style, ctx.writer),
            .markdown => |args| try markdown.render(args.span, args.filename, args.options, ctx.reporter, ctx.writer),
            .template => |template| try template.exec(ctx, scope),
            else => |value| return ctx.reporter.failAt(
                self.filename,
                command.location,
                "{s}: expected string variable, got {s}",
                .{ variable, @tagName(value) },
            ),
        },
        .control => |control| switch (try self.lookup(ctx, scope, command, control.variable)) {
            .bool => |value| if (value) {
                try control.body.exec(ctx, scope);
            } else if (control.else_body) |else_body| {
                try else_body.exec(ctx, scope);
            },
            .array => |array| if (array.items.len == 0) {
                if (control.else_body) |else_body| try else_body.exec(ctx, scope);
            } else {
                var child = scope.initChild(undefined);
                for (array.items) |item| try control.body.exec(ctx, child.reset(item));
            },
            else => |value| blk: {
                switch (value) {
                    .string => |optional| if (optional == null) {
                        if (control.else_body) |else_body| try else_body.exec(ctx, scope);
                        break :blk;
                    },
                    else => {},
                }
                var child = scope.initChild(value);
                try control.body.exec(ctx, &child);
            },
        },
    };
}

fn expectExecuteSuccess(expected: []const u8, source: []const u8, object: anytype, includes: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var include_map = std.StringHashMap(Template).init(allocator);
    const fields = @typeInfo(@TypeOf(includes)).Struct.fields;
    inline for (fields) |field| {
        try include_map.put(field.name, undefined);
    }
    inline for (fields) |field| {
        var scanner = Scanner{ .source = @field(includes, field.name), .reporter = &reporter };
        include_map.getPtr(field.name).?.* = try parse(allocator, &scanner, include_map);
    }
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var template = try parse(allocator, &scanner, include_map);
    var value = try Value.init(allocator, object);
    var scope = Scope.init(value);
    var actual = std.ArrayList(u8).init(allocator);
    try template.execute(allocator, &reporter, actual.writer(), &scope);
    try testing.expectEqualStrings(expected, actual.items);
}

fn expectExecuteFailure(expected_message: []const u8, source: []const u8, object: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var include_map = std.StringHashMap(Template).init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var template = try parse(allocator, &scanner, include_map);
    var value = try Value.init(allocator, object);
    var scope = Scope.init(value);
    try reporter.expectFailure(
        expected_message,
        template.execute(allocator, &reporter, std.io.null_writer, &scope),
    );
}

test "execute text" {
    try expectExecuteSuccess("", "", .{}, .{});
    try expectExecuteSuccess("Hello world!", "Hello world!", .{}, .{});
}

test "execute variable" {
    try expectExecuteSuccess("foo", "{{ . }}", "foo", .{});
    try expectExecuteSuccess("foo bar", "{{ x }} {{ y }}", .{ .x = "foo", .y = "bar" }, .{});
}

test "execute shadowing" {
    try expectExecuteSuccess("aba", "{{ x }}{{ if y }}{{ x }}{{ end }}{{ x }}", .{ .x = "a", .y = .{ .x = "b" } }, .{});
    try expectExecuteSuccess("aaa", "{{ x }}{{ if y }}{{ x }}{{ end }}{{ x }}", .{ .x = "a", .y = .{ .z = "b" } }, .{});
}

test "execute definition" {
    try expectExecuteSuccess("foo", "{{ define x }}foo{{ end }}{{ x }}", .{}, .{});
    try expectExecuteSuccess("foo", "{{ define x }}foo{{ end }}{{ x }}", .{ .x = "bar" }, .{});
}

test "execute if" {
    try expectExecuteSuccess("yes", "{{ if val }}yes{{ end }}", .{ .val = true }, .{});
    try expectExecuteSuccess("", "{{ if val }}yes{{ end }}", .{ .val = false }, .{});
}

test "execute if-else bool" {
    try expectExecuteSuccess("yes", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = true }, .{});
    try expectExecuteSuccess("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = false }, .{});
}

test "execute if-else string" {
    try expectExecuteSuccess("yes", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = "" }, .{});
    try expectExecuteSuccess("yes", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = @as(?[]const u8, "") }, .{});
    try expectExecuteSuccess("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = @as(?[]const u8, null) }, .{});
}

test "execute range" {
    try expectExecuteSuccess("Alice,Bob,", "{{ range . }}{{ . }},{{ end }}", .{ "Alice", "Bob" }, .{});
}

test "execute range-else" {
    try expectExecuteSuccess("empty!", "{{ range . }}{{ . }},{{ else }}empty!{{ end }}", .{}, .{});
}

test "execute not a string" {
    try expectExecuteFailure("<input>:1:1: .: expected string variable, got array", "{{ . }}", .{});
}

test "execute variable not found" {
    try expectExecuteFailure("<input>:1:7: foo: variable not found", "Hello {{ foo }}!", .{});
}

test "execute everything" {
    try expectExecuteSuccess(
        \\From base:
        \\        Value: inner bar,
        \\        Value: foo,
    ,
        \\{{ include "base.html" }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}Fallback{{end}},
        \\    {{ end }}
        \\{{ end }}
    ,
        .{ .bar = true, .thing = .{ .{ .bar = "inner bar" }, "foo" } },
        .{ .@"base.html" = "From base:{{ var }}" },
    );
}
