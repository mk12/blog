// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Scanner = @import("Scanner.zig");

const Definition = struct {
    variable: []const u8,
    body: *const Template,
};

const Command = struct {
    pos: Scanner.Position,
    cmd: union(enum) {
        text: []const u8,
        include: ?*const Template,
        variable: []const u8,
        control: struct {
            variable: []const u8,
            body: *const Template,
            elseBody: *const Template,
        },
    },
};

pub const Template = struct {
    path: []const u8,
    defs: []Definition,
    cmds: []Command,

    fn compile(allocator: Allocator, scanner: *Scanner) !Template {
        _ = scanner;
        var defs = std.ArrayList(Definition).init(allocator);
        _ = defs;
        var cmds = std.ArrayList(Command).init(allocator);
        _ = cmds;
    }
};
