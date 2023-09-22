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
    // Terminators
    eof,
    @"\n",
    @"$",
    // Direct MathML
    mtext,
    mfrac,
    msqrt,
    mphantom,
    mo: []const u8,
    mi: []const u8,
    mn: []const u8,
    mover: []const u8,
    mspace: []const u8,
    mathvariant: []const u8,
    mo_nonstretchy: []const u8,
    // Other
    @"{",
    @"}",
    stretchy,
    _,
    @"^",
    boxed,
};

fn lookupMacro(name: []const u8) ?Token {
    const list = .{
        // Special
        .{ "text", .mtext },
        .{ "frac", .mfrac },
        .{ "sqrt", .msqrt },
        .{ "phantom", .mphantom },
        .{ "boxed", .boxed },
        // Spacing
        .{ "quad", .{ .mspace = "1em " } },
        // Fonts
        .{ "mathbb", .{ .mathvariant = "double-struck" } },
        .{ "mathbf", .{ .mathvariant = "bold" } },
        .{ "mathcal", .{ .mathvariant = "script" } },
        .{ "mathrm", .{ .mathvariant = "normal" } },
        // Delimiters
        .{ "left", .stretchy },
        .{ "right", .stretchy },
        .{ "lvert", .{ .mo_nonstretchy = "|" } },
        .{ "rvert", .{ .mo_nonstretchy = "|" } },
        .{ "lVert", .{ .mo_nonstretchy = "‖" } },
        .{ "rVert", .{ .mo_nonstretchy = "‖" } },
        .{ "langle", .{ .mo_nonstretchy = "⟨" } },
        .{ "rangle", .{ .mo_nonstretchy = "⟩" } },
        // Accents
        .{ "vec", .{ .mover = "→" } },
        .{ "hat", .{ .mover = "^" } },
        // Functions
        .{ "log", .{ .mi = "log" } },
        .{ "lim", .{ .mi = "lim" } },
        // Letters
        .{ "aleph", .{ .mi = "ℵ" } },
        .{ "alpha", .{ .mi = "α" } },
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
        .{ "odot", .{ .mo = "⊙" } },
        .{ "oplus", .{ .mo = "⊕" } },
        .{ "pm", .{ .mo = "±" } },
        .{ "setminus", .{ .mo = "∖" } },
        .{ "subseteq", .{ .mo = "⊆" } },
        .{ "sum", .{ .mo = "∑" } },
        .{ "times", .{ .mo = "×" } },
        .{ "to", .{ .mo = "→" } },
    };
    return std.ComptimeStringMap(Token, list).get(name);
}

fn scan(scanner: *Scanner) !Token {
    scanner.skipMany(' ');
    const start = scanner.offset;
    return switch (scanner.next() orelse return .eof) {
        inline '\n', '$', '{', '}', '_', '^' => |char| @field(Token, &.{char}),
        'a'...'z', 'A'...'Z' => .{ .mi = scanner.source[start..scanner.offset] },
        '(', ')', '[', ']', '+', '-', '=', '<', '>', ',' => .{ .mo = scanner.source[start..scanner.offset] },
        '0'...'9' => blk: {
            while (scanner.peek()) |char| switch (char) {
                '0'...'9', '.' => scanner.eat(),
                else => break,
            };
            break :blk .{ .mn = scanner.source[start..scanner.offset] };
        },
        '\\' => blk: {
            const macro_start = scanner.offset;
            while (scanner.peek()) |char| switch (char) {
                'a'...'z', 'A'...'Z' => scanner.eat(),
                else => break,
            };
            const name = scanner.source[macro_start..scanner.offset];
            if (name.len == 0) return scanner.fail("expected a macro name", .{});
            break :blk lookupMacro(name) orelse scanner.failOn(name, "unknown macro", .{});
        },
        else => scanner.failOn(scanner.source[start..scanner.offset], "unexpected character", .{}),
    };
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
    try expectTokens(&[_]Token{.eof}, "");
}

test "scan blank line" {
    try expectTokens(&[_]Token{ .@"\n", .eof }, "\n");
}

test "scan variable" {
    try expectTokens(&[_]Token{ .{ .mi = "x" }, .eof }, "x");
}

test "scan quadratic formula" {
    try expectTokens(&[_]Token{
        .{ .mi = "x" },
        .{ .mo = "=" },
        .{ .mo = "-" },
        .{ .mi = "b" },
        .{ .mo = "±" },
        .mfrac,
        .@"{",
        .msqrt,
        .@"{",
        .{ .mi = "b" },
        .@"^",
        .{ .mn = "2" },
        .{ .mo = "-" },
        .{ .mn = "4" },
        .{ .mi = "a" },
        .{ .mi = "c" },
        .@"}",
        .@"}",
        .@"{",
        .{ .mn = "2" },
        .{ .mi = "a" },
        .@"}",
        .eof,
    },
        \\x = -b \pm \frac{\sqrt{b^2 - 4ac}}{2a}
    );
}

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
    // + skip over whitespace
    // - state: whether currently in mrow (probably have stack)
    // - remember prev (e.g. x+y or x,+y depends on lhs of +)
    // - see next (to know whether we need an mrow, to know if ^ or _ comes next)
    //   - or maybe not about mrow; seems unnecessary at top level
    //   - still applies tho e.g. in mfrac (if next is }, don't bother with mrow)
    // - enforce \mathxx{V} can only have one character, that way
    //   \mathbb{R}^2 sees ^ immediately after and the peeking/prev thing works
    //   ... or not. just work generally with { ... } ?
    //   also what if \mathbf { x } separate lines
    // - In (1+2)^2 z, want to see "^" "(" ... ")" z  (notice it skipped over ^ at end)
    //
    // \sum_1^2 is munderover
    // \int_1^2 is msubsup
    // \mathbb{R}^2 common

    // Deciding to do it the lazy way, e.g. |x+y|^2, just the final | is in the msup
    // Then don't need to track parens at all, can just be mo's
    // for \mathbb{R}^2, can have renderer fetch more tokens and assert?
    // \sum_{...}^{...} is hard
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
