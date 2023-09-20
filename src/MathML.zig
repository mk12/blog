// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module renders a subset of TeX to MathML.
//! It scans input until a closing "$" or "$$" delimiter, and it yields control
//! when it encounters a newline, so it can be used by the Markdown renderer.

const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const assert = std.debug.assert;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const MathML = @This();

kind: Kind,

pub const Kind = enum {
    @"inline",
    display,

    pub fn delimiter(self: Kind) []const u8 {
        return switch (self) {
            .@"inline" => "$",
            .display => "$$",
        };
    }
};

const Token = union(enum) {
    end_of_file,
    end_of_line,
    end_of_math,
    mtext,
    msub,
    msup,
    mfrac,
    mo: []const u8,
    mi: []const u8,
    mn: []const u8,
    mover: []const u8,
    mathvariant: []const u8,
    open_stretchy,
    close_stretchy,
    open: Delimiter,
    close: Delimiter,

    fn notEof(self: Token) ?Token {
        return if (self == .end_of_file) null else self;
    }
};

const Delimiter = enum {
    brace,
    paren,
    angle,
    vert,
    double_vert,
};

fn lookupMacro(name: []const u8) Token {
    const list = .{
        // Special
        .{ "text", .mtext },
        .{ "frac", .mrac },
        // Fonts
        .{ "mathbb", .{ .mathvariant = "double-struck" } },
        .{ "mathbf", .{ .mathvariant = "bold" } },
        .{ "mathcal", .{ .mathvariant = "script" } },
        .{ "mathrm", .{ .mathvariant = "normal" } },
        // Delimiters
        .{ "left", .open_stretchy },
        .{ "right", .close_stretchy },
        .{ "lvert", .{ .open = .vert } },
        .{ "rvert", .{ .close = .vert } },
        .{ "lVert", .{ .open = .double_vert } },
        .{ "rVert", .{ .close = .double_vert } },
        .{ "langle", .{ .open = .angle } },
        .{ "rangle", .{ .open = .angle } },
        // Accents
        .{ "vec", .{ .mover = "→" } },
        .{ "hat", .{ .mover = "^" } },
        // Letters
        .{ "aleph", .{ .mi = "ℵ" } },
        .{ "chi", .{ .mi = "χ" } },
        .{ "epsilon", .{ .mi = "ϵ" } },
        .{ "gamma", .{ .mi = "γ" } },
        .{ "lambda", .{ .mi = "λ" } },
        .{ "mu", .{ .mi = "μ" } },
        .{ "omega", .{ .mi = "ω" } },
        // Symbols
        .{ "bigcirc", .{ .mi = "◯" } },
        .{ "bigtriangleup", .{ .mi = "△" } },
        .{ "circ", .{ .mi = "∘" } },
        .{ "ddots", .{ .mi = "⋱" } },
        .{ "dots", .{ .mi = "…" } },
        .{ "exists", .{ .mi = "∃" } },
        .{ "forall", .{ .mi = "∀" } },
        .{ "infty", .{ .mi = "∞" } },
        .{ "partial", .{ .mi = "∂" } },
        .{ "square", .{ .mi = "□" } },
        .{ "vdots", .{ .mi = "⋮" } },
        // Operators
        .{ "approx", .{ .mo = "≈" } },
        .{ "ast", .{ .mo = "∗" } },
        .{ "bullet", .{ .mo = "∙" } },
        .{ "cdot", .{ .mo = "⋅" } },
        .{ "colon", .{ .mo = ":" } },
        .{ "cup", .{ .mo = "∪" } },
        .{ "ge", .{ .mo = "≥" } },
        .{ "in", .{ .mo = "∈" } },
        .{ "le", .{ .mo = "≤" } },
        .{ "mapsto", .{ .mo = "↦" } },
        .{ "ne", .{ .mo = "≠" } },
        .{ "notin", .{ .mo = "∉" } },
        .{ "oplus", .{ .mo = "⊕" } },
        .{ "pm", .{ .mo = "±" } },
        .{ "setminus", .{ .mo = "∖" } },
        .{ "subseteq", .{ .mo = "⊆" } },
        .{ "sum", .{ .mo = "∑" } },
        .{ "times", .{ .mo = "×" } },
        .{ "to", .{ .mo = "→" } },
    };
    return std.ComptimeStringMap(Token, list).get(name) orelse .{ .mi = name };
}

fn scan(scanner: *Scanner) Token {
    const start = scanner.offset;
    switch (scanner.next() orelse return .end_of_file) {
        '\n' => return .end_of_line,
        '$' => return .end_of_math,
        '{' => return .{ .open = .brace },
        '}' => return .{ .close = .brace },
        '(' => return .{ .open = .paren },
        ')' => return .{ .close = .paren },
        '\\' => {
            while (scanner.peek()) |char| switch (char) {
                'a'...'z', 'A'...'Z' => scanner.eat(),
                else => break,
            };
            // TODO exclude \, and handle case where no letters after
            return lookupMacro(scanner.source[start..scanner.offset]);
        },
        '0'...'9' => {
            while (scanner.peek()) |char| switch (char) {
                '0'...'9', '.' => scanner.eat(),
                else => break,
            };
            return .{ .mn = scanner.source[start..scanner.offset] };
        },
        'a'...'z', 'A'...'Z' => return .{ .mi = scanner.source[start..scanner.offset] },
        '+', '-', '=', '<', '>', ',' => return .{ .mo = scanner.source[start..scanner.offset] },
    }
}

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual = std.ArrayList(Token).init(allocator);
    while (scan(&scanner).notEof()) |token| try actual.append(token);
    try testing.expectEqualDeep(expected, actual.items);
}

test "scan empty string" {
    try expectTokens(&[_]Token{}, "");
}

test "scan variable" {
    try expectTokens(&[_]Token{}, "x");
}

// x = - b \pm \frac{\sqrt{b^2 - 4 a c}}{2 a}
// Tokens:
// mi x
// mo =
// mo -
// mi b
// mi ±
// mfrac
// {
// msqrt
// {
// msup   <-------
// mi b
// mn 2
// mo -
// mn 4
// mi a
// mi c
// }
// }
// {
// mn 2
// mi a
// }

pub fn init(writer: anytype, kind: Kind) !MathML {
    switch (kind) {
        .@"inline" => try writer.writeAll("<math>"),
        .display => try writer.writeAll("<math display=\"block\">"),
    }
    return MathML{ .kind = kind };
}

pub fn render(self: *MathML, writer: anytype, scanner: *Scanner) !bool {
    _ = self;
    assert(!scanner.eof());
    while (scanner.next()) |char| switch (char) {
        '$' => return true,
        '\\' => unreachable,
        '0'...'9' => unreachable, // <mn>
        '(', ')', '=' => try fmt.format(writer, "<mo>{c}</mo>", .{char}),
        else => try fmt.format(writer, "<mi>{c}</mi>", .{char}),
    };

    // requirements:
    // - skip over whitespace
    // - state: whether currently in mrow (probably have stack)
    // - remember prev (e.g. x+y or x,+y depends on lhs of +)
    // - see next (to know whether we need an mrow, to know if ^ or _ comes next)
    //   - or maybe not about mrow; seems unnecessary at top level
    //   - still applies tho e.g. in mfrac
    // - enforce \mathxx{V} can only have one character, that way
    //   \mathbb{R}^2 sees ^ immediately after and the peeking/prev thing works
    // - In (1+2)^2 z, want to see "(" "^" ... ")" z  (notice it skipped over ^ at end)
    // - or make the ^ come first, then more like frac
    return false;
}

fn renderEnd(self: *MathML, writer: anytype) !void {
    _ = self;
    try writer.writeAll("</math>");
}

fn expect(expected_mathml: []const u8, source: []const u8, kind: Kind) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_mathml = std.ArrayList(u8).init(allocator);
    const writer = actual_mathml.writer();
    var math = try init(writer, kind);
    while (!scanner.eof()) _ = try math.render(writer, &scanner);
    try math.renderEnd(writer);
    try testing.expectEqualStrings(expected_mathml, actual_mathml.items);
}

test "empty input" {
    try expect("<math></math>", "", .@"inline");
    try expect("<math display=\"block\"></math>", "", .display);
}

test "variable" {
    try expect("<math><mi>x</mi></math>", "x", .@"inline");
    try expect("<math display=\"block\"><mi>x</mi></math>", "x", .display);
}
