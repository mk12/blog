// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module implements a templating system inspired by Go's text/template.
//! Templates must be parsed first, and then can be executed multiple times.
//!
//! The syntax is as follows:
//!
//!     {{ foo }}                              insert a variable
//!     {{ if foo }}...{{ end }}               if statement
//!     {{ if foo }}...{{ else }}...{{ end }}  if-else statement
//!     {{ range foo }}...{{ end }}            range over a collection
//!     {{ include "file.html" }}              include another template
//!     {{ define foo }}...{{ end }}           define a variable as sub-template
//!
//! A value is either null, a bool, string, array of values, dictionary from
//! strings to values, sub-template, date object, or Markdown object.
//!
//! Everything is truthy except false, null, empty arrays, and empty strings.
//! {{ if }} is actually an alias for {{ range }}; ranging over a non-array
//! iterates 0 or 1 times (and executes {{ else }} if 0 times). Within a range,
//! {{ . }} is bound to the item. If the item is a dictionary, its fields are
//! brought into scope as variables as well.
//!
//! When {{ if }}, {{ range}}, {{ else }}, or {{ end }} are preceded on their
//! line only by whitespace, all prior whitespace (even before the line) is
//! trimmed, similar to {{- foo }} in Go templates.
//!
//! You can express Jinja-style inheritance like this:
//!
//!     <!-- base.html -->
//!     This is the base.
//!     {{ body }}
//!
//!     <!-- index.html -->
//!     {{ include "base.html" }}
//!     {{ define body }}...{{ end }}
//!
//! This works because definitions are hoisted and dynamically scoped.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const fmtEscapes = std.zig.fmtEscapes;
const Allocator = mem.Allocator;
const Date = @import("Date.zig");
const EnumSet = std.enums.EnumSet;
const Markdown = @import("Markdown.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Scanner = @import("Scanner.zig");
const Template = @This();

source: []const u8,
filename: []const u8,
definitions: std.ArrayListUnmanaged(Definition) = .{},
commands: std.ArrayListUnmanaged(Command) = .{},

const Variable = []const u8;

const Token = union(enum) {
    text: []const u8,
    include: []const u8, // template path
    variable: Variable,
    define: Variable,
    start: Variable, // "if" or "range"
    @"else",
    end,
};

fn scan(scanner: *Scanner) Reporter.Error!?Token {
    const braces = "{{";
    const text = scanUntilStringOrEof(scanner, braces);
    if (text.len != 0) return .{ .text = text };
    if (scanner.eof()) return null;
    scanner.offset += braces.len;
    scanner.skipWhile(' ');
    const word = try scanIdentifier(scanner);
    scanner.skipWhile(' ');
    const Kind = enum { variable, include, define, @"if", range, @"else", end };
    const kind = std.meta.stringToEnum(Kind, word) orelse .variable;
    const token: Token = switch (kind) {
        .variable => .{ .variable = word },
        .include => .{
            .include = blk: {
                try scanner.expect('"');
                const path = scanner.consumeLineUntil('"') orelse
                    return scanner.fail("unclosed '\"'", .{});
                scanner.skipWhile(' ');
                break :blk path;
            },
        },
        .define => .{
            .define = blk: {
                const variable = try scanIdentifier(scanner);
                scanner.skipWhile(' ');
                break :blk variable;
            },
        },
        .@"if", .range => .{
            .start = blk: {
                const variable = try scanIdentifier(scanner);
                scanner.skipWhile(' ');
                break :blk variable;
            },
        },
        .@"else" => .@"else",
        .end => .end,
    };
    try scanner.expectString("}}");
    return token;
}

fn scanUntilStringOrEof(scanner: *Scanner, string: []const u8) []const u8 {
    const start = scanner.offset;
    scanner.offset = mem.indexOfPos(u8, scanner.source, scanner.offset, string) orelse scanner.source.len;
    return scanner.source[start..scanner.offset];
}

fn scanIdentifier(scanner: *Scanner) ![]const u8 {
    const start = scanner.offset;
    while (scanner.peek()) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.' => scanner.eat(),
        else => break,
    };
    if (scanner.offset == start) return scanner.fail("expected an identifier", .{});
    return scanner.source[start..scanner.offset];
}

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual = std.ArrayList(Token).init(allocator);
    while (try scan(&scanner)) |token| try actual.append(token);
    try testing.expectEqualDeep(expected, actual.items);
}

test "scan empty string" {
    try expectTokens(&[_]Token{}, "");
}

test "scan text" {
    try expectTokens(&[_]Token{.{ .text = "foo\n" }}, "foo\n");
}

test "scan text and variable" {
    try expectTokens(&[_]Token{
        .{ .text = "Hello " },
        .{ .variable = "name" },
        .{ .text = "!" },
    },
        \\Hello {{ name }}!
    );
}

test "scan everything" {
    try expectTokens(&[_]Token{
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

const Command = union(enum) {
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
    var template = Template{ .source = scanner.source, .filename = scanner.filename };
    var terminator_offset: usize = undefined;
    const terminator: Terminator = while (true) {
        terminator_offset = scanner.offset;
        const token = try scan(scanner) orelse break .eof;
        const command: Command = switch (token) {
            .define => |variable| {
                template.trimLastIfText();
                try template.definitions.append(ctx.allocator, Definition{
                    .variable = variable,
                    .body = try parseUntil(ctx, .end, .trim_start),
                });
                continue;
            },
            .end => break .end,
            .@"else" => break .@"else",
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
                    return scanner.failAtPtr(path.ptr, "{s}: template not found", .{path}),
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
        try template.commands.append(ctx.allocator, command);
    };
    template.trimLastIfText();
    if (!allowed_terminators.contains(terminator)) {
        return scanner.failAtOffset(terminator_offset, "unexpected {s}", .{
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
    try testing.expectEqualSlices(Command, &.{Command{ .text = source }}, template.commands.items);
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
    const range_thing = var_body[0].control;
    try testing.expectEqualStrings("thing", range_thing.variable);
    try testing.expectEqual(@as(usize, 0), range_thing.body.definitions.items.len);
    const range_body = range_thing.body.commands.items;
    try testing.expectEqual(@as(usize, 3), range_body.len);
    try testing.expectEqual(@as(?Template, null), range_thing.else_body);
    try testing.expectEqualStrings("\n        Value: ", range_body[0].text);
    const if_bar = range_body[1].control;
    try testing.expectEqualStrings(",", range_body[2].text);
    try testing.expectEqual(@as(usize, 0), if_bar.body.definitions.items.len);
    try testing.expectEqual(@as(usize, 0), if_bar.else_body.?.definitions.items.len);
    const if_body = if_bar.body.commands.items;
    try testing.expectEqual(@as(usize, 1), if_body.len);
    try testing.expectEqualStrings(".", if_body[0].variable);
    const else_body = if_bar.else_body.?.commands.items;
    try testing.expectEqual(@as(usize, 1), else_body.len);
    try testing.expectEqualStrings("Fallback", else_body[0].text);

    const commands = template.commands.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqual(base_template, commands[0].include);
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
        \\<input>:1:27: expected "}}", got EOF
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
        \\<input>:2:13: does_not_exist: template not found
    ,
        \\Some text before.
        \\{{ include "does_not_exist" }}
    );
}

pub const Value = union(enum) {
    null,
    bool: bool,
    string: []const u8,
    array: std.ArrayListUnmanaged(Value),
    dict: std.StringHashMapUnmanaged(Value),
    template: *const Template,
    date: struct { date: Date, style: Date.Style },
    markdown: struct { markdown: Markdown, options: Markdown.Options },

    pub fn init(allocator: Allocator, object: anytype) !Value {
        return switch (@typeInfo(@TypeOf(object))) {
            .Optional => if (object) |obj| initNonOptional(allocator, obj) else .null,
            else => initNonOptional(allocator, object),
        };
    }

    fn initNonOptional(allocator: Allocator, object: anytype) !Value {
        const Type = @TypeOf(object);
        switch (Type) {
            Value => return object,
            @TypeOf(null) => return .null,
            bool => return .{ .bool = object },
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
        .null = null,
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
    hooks: anytype,
    scope: *Scope,
) !void {
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

fn lookup(self: Template, ctx: anytype, scope: *const Scope, variable: Variable) !Value {
    return scope.lookup(variable) orelse ctx.reporter.failAt(
        self.filename,
        Location.fromPtr(self.source, variable.ptr),
        "{s}: variable not found",
        .{variable},
    );
}

fn exec(self: Template, ctx: anytype, scope: *Scope) !void {
    for (self.definitions.items) |definition|
        try scope.definitions.put(ctx.allocator, definition.variable, &definition.body);
    for (self.commands.items) |command| switch (command) {
        .text => |text| try ctx.writer.writeAll(text),
        .include => |template| try template.exec(ctx, scope),
        .variable => |variable| switch (try self.lookup(ctx, scope, variable)) {
            .string => |string| try ctx.writer.writeAll(string),
            .template => |template| try template.exec(ctx, scope),
            .date => |args| try args.date.render(ctx.writer, args.style),
            .markdown => |args| try args.markdown.render(ctx.reporter, ctx.writer, ctx.hooks, args.options),
            else => |value| return ctx.reporter.failAt(
                self.filename,
                Location.fromPtr(self.source, variable.ptr),
                "{s}: expected string variable, got {s}",
                .{ variable, @tagName(value) },
            ),
        },
        .control => |control| blk: {
            const body = control.body;
            var child = scope.initChild(undefined);
            switch (try self.lookup(ctx, scope, control.variable)) {
                .null => {},
                .bool => |value| if (value) break :blk try body.exec(ctx, scope),
                .string => |string| if (string.len > 0) break :blk try body.exec(ctx, child.reset(Value{ .string = string })),
                .array => |array| if (array.items.len > 0) break :blk for (array.items) |item| try body.exec(ctx, child.reset(item)),
                else => |value| break :blk try body.exec(ctx, child.reset(value)),
            }
            if (control.else_body) |else_body| try else_body.exec(ctx, scope);
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
    try template.execute(allocator, &reporter, actual.writer(), .{}, &scope);
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
        template.execute(allocator, &reporter, std.io.null_writer, .{}, &scope),
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
    try expectExecuteSuccess("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = "" }, .{});
    try expectExecuteSuccess("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = @as(?[]const u8, "") }, .{});
    try expectExecuteSuccess("no", "{{ if val }}yes{{ else }}no{{ end }}", .{ .val = @as(?[]const u8, null) }, .{});
}

test "execute range" {
    try expectExecuteSuccess("Alice,Bob,", "{{ range . }}{{ . }},{{ end }}", .{ "Alice", "Bob" }, .{});
}

test "execute range-else" {
    try expectExecuteSuccess("empty!", "{{ range . }}{{ . }},{{ else }}empty!{{ end }}", .{}, .{});
}

test "execute not a string" {
    try expectExecuteFailure("<input>:1:4: .: expected string variable, got array", "{{ . }}", .{});
}

test "execute variable not found" {
    try expectExecuteFailure("<input>:1:10: foo: variable not found", "Hello {{ foo }}!", .{});
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
