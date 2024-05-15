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
//!     {{ template "file.html" }}             include another template
//!     {{ foo = "..." }}                      define a string variable
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

source: []const u8,
filename: []const u8,
offset: usize,
definitions: std.StringHashMapUnmanaged(Value) = .{},
commands: std.ArrayListUnmanaged(Command) = .{},

const Variable = []const u8;

const Token = union(enum) {
    text: []const u8,
    variable: Variable,
    assign: struct { variable: Variable, string: []const u8 },
    define: Variable,
    @"if": Variable,
    range: Variable,
    terminator: Terminator,
};

const Terminator = enum { eof, end, @"else" };

fn scan(scanner: *Scanner) Reporter.Error!Token {
    const braces = "{{";
    const text = scanner.consumeStopString(braces) orelse scanner.consumeRest();
    if (text.len > 0) return .{ .text = text };
    if (scanner.eof()) return .{ .terminator = .eof };
    scanner.offset += braces.len;
    scanner.skipMany(' ');
    const word = try scanIdentifier(scanner);
    scanner.skipMany(' ');
    const Kind = enum { variable, template, define, @"if", range, @"else", end };
    const kind = std.meta.stringToEnum(Kind, word) orelse .variable;
    const token: Token = switch (kind) {
        .variable => switch (scanner.consume('=')) {
            false => .{ .variable = word },
            true => blk: {
                scanner.skipMany(' ');
                break :blk .{ .assign = .{ .variable = word, .string = try scanStringLiteral(scanner) } };
            },
        },
        .template => .{ .variable = try scanStringLiteral(scanner) },
        inline .define, .@"if", .range => |tag| @unionInit(Token, @tagName(tag), try scanIdentifier(scanner)),
        .@"else" => .{ .terminator = .@"else" },
        .end => .{ .terminator = .end },
    };
    scanner.skipMany(' ');
    try scanner.expectString("}}");
    return token;
}

fn scanIdentifier(scanner: *Scanner) ![]const u8 {
    const start = scanner.offset;
    if (scanner.consume('.')) return scanner.source[start..scanner.offset];
    while (scanner.peek()) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => scanner.eat(),
        else => break,
    };
    if (scanner.offset == start) return scanner.fail("expected an identifier", .{});
    return scanner.source[start..scanner.offset];
}

fn scanStringLiteral(scanner: *Scanner) ![]const u8 {
    try scanner.expect('"');
    const string = scanner.consumeLineUntil('"') orelse return scanner.fail("unclosed '\"'", .{});
    return string;
}

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual = std.ArrayList(Token).init(allocator);
    for (expected) |_| try actual.append(try scan(&scanner));
    try testing.expectEqualDeep(expected, actual.items);
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
        .{ .variable = "name" },
        .{ .text = "!" },
        .{ .terminator = .eof },
    },
        \\Hello {{ name }}!
    );
}

test "scan everything" {
    try expectTokens(&[_]Token{
        .{ .variable = "base.html" },
        .{ .text = "\n" },
        .{ .assign = .{ .variable = "day", .string = "Monday" } },
        .{ .text = "\n" },
        .{ .define = "var" },
        .{ .text = "\n    " },
        .{ .range = "thing" },
        .{ .text = "\n        Value: " },
        .{ .@"if" = "bar" },
        .{ .variable = "." },
        .{ .terminator = .@"else" },
        .{ .text = "day is " },
        .{ .variable = "day" },
        .{ .terminator = .end },
        .{ .text = ",\n    " },
        .{ .terminator = .end },
        .{ .text = "\n" },
        .{ .terminator = .end },
        .{ .terminator = .eof },
    },
        \\{{ template "base.html" }}
        \\{{ day = "Monday" }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}day is {{day}}{{end}},
        \\    {{ end }}
        \\{{ end }}
    );
}

const Command = union(enum) {
    text: []const u8,
    variable: Variable,
    @"if": struct { variable: Variable, body: Template, else_body: ?Template },
    range: struct { variable: Variable, body: Template },
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
            .assign => |assign| {
                template.trimLastIfText();
                try template.definitions.put(allocator, assign.variable, Value{ .string = assign.string });
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
            .variable => |variable| .{ .variable = variable },
            .@"if" => |variable| blk: {
                template.trimLastIfText();
                const end_or_else = EnumSet(Terminator).init(.{ .end = true, .@"else" = true });
                const result = try parseUntilAny(allocator, scanner, end_or_else, .no_trim);
                break :blk .{
                    .@"if" = .{
                        .variable = variable,
                        .body = result.template,
                        .else_body = switch (result.terminator) {
                            .@"else" => try parseUntil(allocator, scanner, .end, .no_trim),
                            else => null,
                        },
                    },
                };
            },
            .range => |variable| blk: {
                template.trimLastIfText();
                break :blk .{
                    .range = .{
                        .variable = variable,
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
    return mem.trimLeft(u8, text, whitespace_chars);
}

fn trimEnd(text: []const u8) []const u8 {
    const index = mem.lastIndexOfScalar(u8, text, '\n') orelse return text;
    if (mem.indexOfNonePos(u8, text, index + 1, whitespace_chars)) |_| return text;
    return mem.trimRight(u8, text[0..index], whitespace_chars);
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
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}day is {{day}}{{end}},
        \\    {{ end }}
        \\{{ end }}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const template = try expectParse(arena.allocator(), source);

    try testing.expectEqualStrings("<input>", template.filename);
    try testing.expectEqual(@as(usize, 0), template.offset);

    const definitions = template.definitions;
    try testing.expectEqual(@as(usize, 2), definitions.count());
    const define_day = definitions.get("day").?.string;
    try testing.expectEqualStrings("Monday", define_day);
    const define_var = definitions.get("var").?.template;
    try testing.expectEqual(@as(usize, 0), define_var.definitions.count());
    try testing.expectEqualStrings("<input>", define_var.filename);
    try testing.expectEqual(@as(usize, 63), define_var.offset);
    const var_body = define_var.commands.items;
    try testing.expectEqual(@as(usize, 1), var_body.len);
    const range_thing = var_body[0].range;
    try testing.expectEqualStrings("thing", range_thing.variable);
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
    try testing.expectEqualStrings(".", if_body[0].variable);
    const else_body = if_bar.else_body.?.commands.items;
    try testing.expectEqual(@as(usize, 2), else_body.len);
    try testing.expectEqualStrings("day is ", else_body[0].text);
    try testing.expectEqualStrings("day", else_body[1].variable);

    const commands = template.commands.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("base.html", commands[0].variable);
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

test "missing string literal" {
    try expectParseFailure(
        \\<input>:1:8: expected "\"", got "}"
    ,
        \\{{ a = }}
    );
}

pub const Value = union(enum) {
    null,
    bool: bool,
    string: []const u8,
    array: std.ArrayListUnmanaged(Value),
    dict: std.StringHashMapUnmanaged(Value),
    pointer: *const Value,
    template: Template,
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
            Template => return .{ .template = object },
            else => {},
        }
        switch (@typeInfo(Type)) {
            .Array => |array_type| return initArray(allocator, object, array_type.child),
            .Pointer => |pointer_type| return if (pointer_type.size == .Slice)
                initArray(allocator, object, pointer_type.child)
            else if (pointer_type.child == Value)
                .{ .pointer = object }
            else switch (@typeInfo(pointer_type.child)) {
                .Array => |array_type| initArray(allocator, object, array_type.child),
                else => @compileError("invalid pointer type: " ++ @typeName(Type)),
            },
            .Struct => |struct_type| if (struct_type.is_tuple) {
                var array = std.ArrayListUnmanaged(Value){};
                inline for (object) |item| try array.append(allocator, try init(allocator, item));
                return .{ .array = array };
            } else {
                var dict = std.StringHashMapUnmanaged(Value){};
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
        if (ItemType == Value and info == .Pointer and !info.Pointer.is_const)
            return .{ .array = std.ArrayListUnmanaged(Value).fromOwnedSlice(object) };
        var array = std.ArrayListUnmanaged(Value){};
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
            .pointer => unreachable,
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
        .value_tuple = .{Value{ .bool = false }},
        .value_array = [1]Value{.{ .bool = false }},
        .value_array_ptr = @as(*const [1]Value, &[1]Value{.{ .bool = false }}),
        .value_slice = @as([]const Value, &[1]Value{.{ .bool = false }}),
        .value_array_ptr_mut = @as(*[1]Value, &value_array_1),
        .value_slice_mut = @as([]Value, &value_array_2),
        .template = try expectParse(arena.allocator(), "template"),
    });
}

pub fn execute(self: Template, allocator: Allocator, reporter: *Reporter, writer: anytype, hooks: anytype, scope: Scope) !void {
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

fn chase(self: Template, ctx: anytype, variable: Variable, value: Value) !Value {
    return switch (value) {
        .pointer => |ptr| switch (ptr.*) {
            .pointer => ctx.reporter.fail(
                self.filename,
                Location.fromPtr(self.source, variable.ptr),
                "{s}: pointer to pointer not allowed",
                .{variable},
            ),
            else => |pointee| pointee,
        },
        else => value,
    };
}

fn lookup(self: Template, ctx: anytype, scope: Scope, variable: Variable) !Value {
    const value = scope.lookup(variable) orelse return ctx.reporter.fail(
        self.filename,
        Location.fromPtr(self.source, variable.ptr),
        "{s}: variable not found",
        .{variable},
    );
    return self.chase(ctx, variable, value);
}

fn exec(self: Template, ctx: anytype, parent: Scope) !void {
    const scope = if (self.definitions.count() == 0) parent else parent.initChild(Value{ .dict = self.definitions });
    for (self.commands.items) |command| switch (command) {
        .text => |text| try ctx.writer.writeAll(text),
        .variable => |variable| switch (try self.lookup(ctx, scope, variable)) {
            .string => |string| try ctx.writer.writeAll(string),
            .template => |template| template.exec(ctx, scope) catch |err| {
                if (err == error.ErrorWasReported) {
                    ctx.reporter.addNote(template.filename, Location.fromOffset(template.source, template.offset), "`{s}` defined here", .{variable});
                    ctx.reporter.addNote(self.filename, Location.fromPtr(self.source, variable.ptr), "`{s}` referenced here", .{variable});
                }
                return err;
            },
            .date => |args| try args.date.render(ctx.writer, args.style),
            .markdown => |args| try args.markdown.render(ctx.reporter, ctx.writer, ctx.hooks, args.options),
            .pointer => unreachable,
            else => |value| return ctx.reporter.fail(
                self.filename,
                Location.fromPtr(self.source, variable.ptr),
                "{s}: cannot render variable of type {s}",
                .{ variable, @tagName(value) },
            ),
        },
        .@"if" => |if_cmd| {
            const value = try self.lookup(ctx, scope, if_cmd.variable);
            if (value.truthy())
                try if_cmd.body.exec(ctx, scope.initChild(value))
            else if (if_cmd.else_body) |body|
                try body.exec(ctx, scope);
        },
        .range => |range| switch (try self.lookup(ctx, scope, range.variable)) {
            .null => {},
            .array => |array| for (array.items) |item| try range.body.exec(ctx, scope.initChild(try self.chase(ctx, range.variable, item))),
            .pointer => unreachable,
            else => |value| return ctx.reporter.fail(
                self.filename,
                Location.fromPtr(self.source, range.variable.ptr),
                "{s}: cannot range over variable of type {s}",
                .{ range.variable, @tagName(value) },
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
    var actual = std.ArrayList(u8).init(allocator);
    try template.execute(allocator, &reporter, actual.writer(), .{}, scope);
    try testing.expectEqualStrings(expected, actual.items);
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
    try reporter.expectFailure(
        expected_message,
        template.execute(allocator, &reporter, std.io.null_writer, .{}, scope),
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

test "execute shadowing" {
    try expectExecute("aba", "{{ x }}{{ if y }}{{ x }}{{ end }}{{ x }}", .{ .x = "a", .y = .{ .x = "b" } });
    try expectExecute("aaa", "{{ x }}{{ if y }}{{ x }}{{ end }}{{ x }}", .{ .x = "a", .y = .{ .z = "b" } });
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

test "execute range" {
    try expectExecute("Alice,Bob,", "{{ range . }}{{ . }},{{ end }}", .{ "Alice", "Bob" });
}

test "execute not a string" {
    try expectExecuteFailure("<input>:1:4: .: cannot render variable of type array", "{{ . }}", .{});
}

test "execute variable not found" {
    try expectExecuteFailure("<input>:1:10: foo: variable not found", "Hello {{ foo }}!", .{});
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

test "execute everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try expectExecute(
        \\From base:
        \\        Value: inner bar,
        \\        Value: day is Monday,
    ,
        \\{{ template "base.html" }}
        \\{{ day = "Monday" }}
        \\{{ define var }}
        \\    {{ range thing }}
        \\        Value: {{if bar}}{{.}}{{else}}day is {{day}}{{end}},
        \\    {{ end }}
        \\{{ end }}
    ,
        .{
            .bar = false,
            .thing = .{ .{ .bar = "inner bar" }, "foo" },
            .@"base.html" = try expectParse(arena.allocator(), "From base:{{ var }}"),
        },
    );
}
