// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("Scanner.zig");
const Template = @This();

definitions: std.ArrayList(Definition),
commands: std.ArrayList(Command),

const Definition = struct {
    variable: []const u8,
    body: Template,
};

const Command = struct {
    pos: Scanner.Position,
    value: union(enum) {
        text: []const u8,
        include: ?*const Template,
        variable: []const u8,
        control: struct {
            variable: []const u8,
            body: Template,
            elseBody: Template,
        },
    },
};

pub fn parse(scanner: *Scanner) !Template {
    const allocator = scanner.allocator;
    var definitions = std.ArrayList(Definition).init(allocator);
    errdefer definitions.deinit();
    var commands = std.ArrayList(Command).init(allocator);
    errdefer commands.deinit();
    // while (true) {
    //     const text = scanner.consumeUntil('{');
    //     _ = text;
    // }
    return Template{ .definitions = definitions, .commands = commands };
}
