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

const Macro = union(enum) {
    frac,
    mo: []const u8,
    mi: []const u8,
    over: []const u8,
    text,
    mathrm,
    mathbb,
    mathbf,
    mathcal,
    lvert,
    rvert,
    langle,
    rangle,
};

fn lookupMacro(name: []const u8) Macro {
    const list = .{
        .{ "sum", .{ .mo = "∑" } },
        .{ "dots", .{ .mo = "…" } },
        .{ "vdots", .{ .mo = "⋮" } },
        .{ "ddots", .{ .mo = "⋱" } },
        .{ "approx", .{ .mo = "≈" } },
        .{ "circ", .{ .mi = "∘" } },
        .{ "bigcirc", .{ .mi = "◯" } },
        .{ "square", .{ .mi = "□" } },
        .{ "bigtriangleup", .{ .mi = "△" } },
        .{ "to", .{ .mo = "→" } },
        .{ "mapsto", .{ .mo = "↦" } },
        .{ "frac", .frac },
        .{ "mathrm", .mathrm },
        .{ "mathbb", .mathbb },
        .{ "mathbf", .mathbf },
        .{ "mathcal", .mathcal },
        .{ "chi", .{ .mi = "χ" } },
        .{ "aleph", .{ .mi = "ℵ" } },
        .{ "gamma", .{ .mi = "γ" } },
        .{ "lambda", .{ .mi = "λ" } },
        .{ "mu", .{ .mi = "μ" } },
        // TODO write this directly in markdown? (have to recognize UTF-8 a bit)
        .{ "le", .{ .mo = "≤" } },
        .{ "ge", .{ .mo = "≥" } },
        .{ "ne", .{ .mo = "≠" } },
        .{ "pm", .{ .mo = "±" } },
        .{ "colon", .{ .mo = ":" } }, // FIXME write ":" directly?
        .{ "epsilon", .{ .mi = "ϵ" } },
        .{ "omega", .{ .mi = "ω" } },
        .{ "infty", .{ .mi = "∞" } },
        .{ "cup", .{ .mo = "∪" } },
        .{ "cdot", .{ .mo = "⋅" } }, // mo
        .{ "times", .{ .mo = "×" } },
        .{ "partial", .{ .mi = "∂" } },
        .{ "vec", .{ .over = "→" } },
        .{ "hat", .{ .over = "^" } },
        .{ "text", .text },
        .{ "lvert", .lvert }, // TODO: lVert, rVert?
        .{ "rvert", .rvert },
        .{ "langle", .langle },
        .{ "rangle", .rangle },
        .{ "in", .{ .mo = "∈" } },
        .{ "notin", .{ .mo = "∉" } },
        .{ "subseteq", .{ .mo = "⊆" } },
        .{ "setminus", .{ .mo = "∖" } },
        .{ "ast", .{ .mo = "∗" } },
        .{ "bullet", .{ .mo = "∙" } },
        .{ "oplus", .{ .mo = "⊕" } },
        .{ "forall", .{ .mi = "∀" } },
        .{ "exists", .{ .mi = "∃" } },
        // No \lim, \log.. backslash = <mi> for whole word
    };
    return std.ComptimeStringMap(Macro, list).get(name);
}

const Token = enum {
    end,
    variable,
    operator,
    mathbb,
    @"_",
    @"^",
};

const Tokenizer = struct {
    peeked: ?Token,

    fn init(scanner: *Scanner) Tokenizer {
        return Tokenizer{ .peeked = scan(null, scanner) };
    }

    fn next(self: *Tokenizer, scanner: *Scanner) ?Token {
        const token = self.peeked orelse return null;
        self.peeked = scan(self.peeked, scanner);
        return token;
    }

    fn scan(prev: ?Token, scanner: *Scanner) ?Token {
        _ = scanner;
        _ = prev;
    }
};

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = Tokenizer.init(&scanner);
    var actual = std.ArrayList(Token).init(allocator);
    while (try tokenizer.next(&scanner)) |token| try actual.append(token);
    try testing.expectEqualDeep(expected, actual.items);
}

test "scan empty string" {
    try expectTokens(&[_]Token{}, "");
}

test "scan empty string" {
    try expectTokens(&[_]Token{}, "");
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
