// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module renders a subset of TeX to MathML.
//! It scans input until a closing "$" or "$$" delimiter, and it yields control
//! when it encounters a newline, so it can be used by the Markdown renderer.

const std = @import("std");
const fmt = std.fmt;
const tag_stack = @import("tag_stack.zig");
const testing = std.testing;
const assert = std.debug.assert;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const TagStack = tag_stack.TagStack;
const MathML = @This();

kind: Kind,
tokenizer: Tokenizer = .{},
prev_token: Token = .null,
stack: TagStack(Tag) = .{},
variant_stack: std.BoundedArray(Variant, max_nested_variants) = .{},
buffer: ?std.BoundedArray(Token, max_buffered_tokens) = null,

const max_nested_variants = 4;
const max_buffered_tokens = 8;

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
    // Special
    null,
    eol,
    @"$",
    // MathML tags
    mfrac,
    msqrt,
    mphantom,
    mtext_start,
    mtext_content: []const u8,
    mtext_end,
    mn: []const u8,
    mi: []const u8,
    mo: []const u8,
    mo_delimiter: []const u8,
    mspace: []const u8,
    // Other
    @"{",
    @"}",
    _,
    @"^",
    @"&",
    @"\\",
    stretchy,
    boxed,
    accent: []const u8,
    variant: Variant,
    begin: Environment,
    end: Environment,
};

const Variant = enum {
    normal,
    bold,
    double_struck,
    script,
};

const Environment = enum { matrix, bmatrix, cases };

fn lookupMacro(name: []const u8) ?Token {
    const list = .{
        // Special
        .{ "text", .mtext_start },
        .{ "begin", .{ .begin = undefined } },
        .{ "end", .{ .end = undefined } },
        .{ "frac", .mfrac },
        .{ "sqrt", .msqrt },
        .{ "phantom", .mphantom },
        .{ "boxed", .boxed },
        // Spacing
        .{ "quad", .{ .mspace = "1em" } },
        // Fonts
        .{ "mathbb", .{ .variant = .double_struck } },
        .{ "mathbf", .{ .variant = .bold } },
        .{ "mathcal", .{ .variant = .script } },
        .{ "mathrm", .{ .variant = .normal } },
        // Delimiters
        .{ "left", .stretchy },
        .{ "right", .stretchy },
        .{ "lvert", .{ .mo_delimiter = "|" } },
        .{ "rvert", .{ .mo_delimiter = "|" } },
        .{ "lVert", .{ .mo_delimiter = "‖" } },
        .{ "rVert", .{ .mo_delimiter = "‖" } },
        .{ "langle", .{ .mo_delimiter = "⟨" } },
        .{ "rangle", .{ .mo_delimiter = "⟩" } },
        // Accents
        .{ "vec", .{ .accent = "→" } },
        .{ "hat", .{ .accent = "^" } },
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
        .{ "colon", .{ .mo = ":" } }, // TODO
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

const Tokenizer = struct {
    in_text: bool = false,
    args_left: u8 = 0,

    fn next(self: *Tokenizer, scanner: *Scanner) !Token {
        if (self.in_text) {
            const text = scanner.consumeStopAny("}\n$") orelse scanner.consumeRest();
            if (text.len > 0) return .{ .mtext_content = text };
            if (scanner.consume('}')) {
                self.in_text = false;
                return .mtext_end;
            }
        }
        const consume_multiple_digits = self.args_left == 0;
        self.args_left -|= 1;
        scanner.skipMany(' ');
        const start = scanner.offset;
        return switch (scanner.next() orelse return .eol) {
            '\n' => .eol,
            inline '$', '{', '}', '_', '^' => |char| {
                if (char == '_' or char == '^') self.args_left = 1;
                return @field(Token, &.{char});
            },
            'a'...'z', 'A'...'Z', '?' => .{ .mi = scanner.source[start..scanner.offset] },
            '+', '-', '=', '<', '>', ',', ':', ';', '.' => .{ .mo = scanner.source[start..scanner.offset] },
            '(', ')', '[', ']' => .{ .mo_delimiter = scanner.source[start..scanner.offset] },
            '0'...'9' => {
                if (consume_multiple_digits) while (scanner.peek()) |char| switch (char) {
                    '0'...'9', '.' => scanner.eat(),
                    else => break,
                };
                return .{ .mn = scanner.source[start..scanner.offset] };
            },
            '\\' => {
                if (scanner.consumeAny("{}")) |_| return .{ .mo = scanner.source[start..scanner.offset] };
                const macro_start = scanner.offset;
                while (scanner.peek()) |char| switch (char) {
                    'a'...'z', 'A'...'Z' => scanner.eat(),
                    else => break,
                };
                const name = scanner.source[macro_start..scanner.offset];
                if (name.len == 0) return scanner.fail("expected a macro name", .{});
                var macro = lookupMacro(name) orelse return scanner.failOn(name, "unknown macro", .{});
                switch (macro) {
                    .mtext_start => {
                        try scanner.expect('{');
                        self.in_text = true;
                    },
                    .begin, .end => |*environment| {
                        try scanner.expect('{');
                        const env_name = scanner.consumeLineUntil('}') orelse return scanner.fail("expected '}}'", .{});
                        try scanner.expect('}');
                        environment.* = std.meta.stringToEnum(Environment, env_name) orelse
                            return scanner.failOn(env_name, "unknown environment", .{});
                    },
                    .msqrt, .mphantom, .boxed => self.args_left = 1,
                    .mfrac => self.args_left = 2,
                    else => {},
                }
                return macro;
            },
            else => scanner.failOn(scanner.source[start..scanner.offset], "unexpected character", .{}),
        };
    }
};

fn expectTokens(expected: []const Token, source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var tokenizer = Tokenizer{};
    var actual = std.ArrayList(Token).init(allocator);
    for (expected) |_| try actual.append(try tokenizer.next(&scanner));
    try testing.expectEqualDeep(expected, actual.items);
}

test "scan empty string" {
    try expectTokens(&[_]Token{.eol}, "");
}

test "scan variable" {
    try expectTokens(&[_]Token{ .{ .mi = "x" }, .eol }, "x");
}

test "scan subscript" {
    try expectTokens(&[_]Token{
        .{ .mi = "x" },
        ._,
        .{ .mn = "1" },
        .{ .mn = "2345" },
        .eol,
    }, "x_12345");
}

test "scan fraction" {
    try expectTokens(&[_]Token{
        .mfrac,
        .{ .mn = "1" },
        .{ .mn = "2" },
        .{ .mn = "345" },
        .eol,
    }, "\\frac12345");
}

test "scan text" {
    try expectTokens(&[_]Token{
        .{ .mi = "x" },
        .{ .mo = "+" },
        .mtext_start,
        .{ .mtext_content = "some stuff" },
        .eol,
        .{ .mtext_content = "more here" },
        .mtext_end,
        .{ .mo = "-" },
        .{ .mi = "y" },
        .eol,
    },
        \\x + \text{some stuff
        \\more here} - y
    );
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
        .eol,
    },
        \\x = -b \pm \frac{\sqrt{b^2 - 4ac}}{2a}
    );
}

const Tag = union(enum) {
    brace,
    mfrac,
    mfrac_1,
    mrow,
    mphantom,
    msqrt,
    msub,
    msup,
    mtext,
    mover,
    munderover,
    boxed,
    accent: []const u8,
    variant: Variant,

    fn closesWithBrace(self: Tag) bool {
        return self == .brace or self == .mrow;
    }

    pub fn writeOpenTag(self: Tag, writer: anytype) !void {
        switch (self) {
            .brace, .mfrac_1, .variant, .accent => {},
            .boxed => try writer.writeAll("<mrow style=\"padding: 0.25em; border: 1px solid\">"),
            else => try fmt.format(writer, "<{s}>", .{@tagName(self)}),
        }
    }

    pub fn writeCloseTag(self: Tag, writer: anytype) !void {
        switch (self) {
            .brace, .mfrac_1, .variant => {},
            .accent => |text| try fmt.format(writer, "<mo stretchy=\"false\">{s}</mo>", .{text}),
            .boxed => try writer.writeAll("</mrow>"),
            else => try fmt.format(writer, "</{s}>", .{@tagName(self)}),
        }
    }
};

pub fn init(writer: anytype, kind: Kind) !MathML {
    switch (kind) {
        .@"inline" => try writer.writeAll("<math>"),
        .display => try writer.writeAll("<math display=\"block\">"),
    }
    return MathML{ .kind = kind };
}

// TODO: Handle ExceededMaxTagDepth with error like Markdown does.
pub fn render(self: *MathML, writer: anytype, scanner: *Scanner) !bool {
    assert(!scanner.eof());
    var window: [3]Token = .{ self.prev_token, try self.tokenizer.next(scanner), .null };
    const finished = while (true) {
        switch (window[1]) {
            .eol => break false,
            .@"$" => {
                if (self.kind == .display) try scanner.expect('$');
                try self.renderEnd(writer);
                break true;
            },
            else => {
                window[2] = try self.tokenizer.next(scanner);
                try self.renderOneToken(writer, window);
                window[0] = window[1];
                window[1] = window[2];
            },
        }
    };
    self.prev_token = window[0];
    return finished;
}

fn renderOneToken(self: *MathML, writer: anytype, window: [3]Token) !void {
    // std.debug.print("----------\ntoken={any}\nstack={any}\n", .{ window[1], self.stack.items.buffer[0..self.stack.items.len] });
    const stack_len = self.stack.len();
    switch (window[2]) {
        ._ => try self.stack.push(writer, .msub),
        .@"^" => try self.stack.push(writer, .msup),
        else => {},
    }
    switch (window[1]) {
        .null, .eol, .@"$" => unreachable,
        .mfrac => try self.stack.append(writer, .{ .mfrac, .mfrac_1 }),
        .msqrt => try self.stack.push(writer, .msqrt),
        .mphantom => try self.stack.push(writer, .mphantom),
        .boxed => try self.stack.push(writer, .boxed),
        .mtext_start => return self.stack.push(writer, .mtext),
        .mtext_content => |text| return writer.writeAll(text),
        .mtext_end => try self.stack.popTag(writer, .mtext),
        .mn => |text| try fmt.format(writer, "<mn>{s}</mn>", .{text}),
        .mi => |text| blk: {
            const styled = if (self.currentVariant()) |variant| switch (variant) {
                .normal => break :blk try fmt.format(writer, "<mi mathvariant=\"normal\">{s}</mi>", .{text}),
                else => getVariantLetter(text, variant) orelse text,
            } else text;
            try fmt.format(writer, "<mi>{s}</mi>", .{styled});
        },
        .mo => |text| try if (window[0] == .null or window[0] == .mo)
            fmt.format(writer, "<mo form=\"prefix\">{s}</mo>", .{text})
        else
            fmt.format(writer, "<mo>{s}</mo>", .{text}),
        .mo_delimiter => |text| try if (window[0] == .stretchy)
            fmt.format(writer, "<mo>{s}</mo>", .{text})
        else
            fmt.format(writer, "<mo stretchy=\"false\">{s}</mo>", .{text}),
        .accent => |text| try self.stack.append(writer, .{ .mover, .{ .accent = text } }),
        .mspace => |width| try fmt.format(writer, "<mspace width=\"{s}\"/>", .{width}),
        .variant => |variant| {
            try self.stack.push(writer, .{ .variant = variant });
            try self.variant_stack.append(variant);
        },
        .@"{" => try self.stack.push(writer, .brace), // or mrow if necessary
        .@"}" => blk: {
            if (self.stack.top()) |tag| if (tag.closesWithBrace()) break :blk try self.stack.pop(writer);
            unreachable; // fail
        },
        ._, .@"^" => return,
        .@"&" => unreachable,
        .@"\\" => unreachable,
        .stretchy => {},
        .begin => |_| unreachable,
        .end => |_| unreachable,
    }
    // or just return early when pushing so don't need to compare len
    if (self.stack.len() <= stack_len)
        while (self.stack.top()) |tag| {
            if (tag.closesWithBrace()) break else try self.stack.popTag(writer, tag);
            if (tag == .mfrac_1) break;
            if (tag == .variant) self.variant_stack.len -= 1;
        };
}

fn renderEnd(self: *MathML, writer: anytype) !void {
    _ = self;
    // check stack and buffer
    try writer.writeAll("</math>");
}

fn currentVariant(self: MathML) ?Variant {
    const len = self.variant_stack.len;
    return if (len == 0) null else self.variant_stack.get(len - 1);
}

fn getVariantLetter(char_str: []const u8, variant: Variant) ?[]const u8 {
    const char = if (char_str.len == 1) char_str[0] else return null;
    const base: enum(u8) { a = 'a', A = 'A' } = switch (char) {
        'a'...'z' => .a,
        'A'...'Z' => .A,
        else => return null,
    };
    const letters: *const [26 * 4:0]u8 = switch (variant) {
        .normal => unreachable,
        .bold => switch (base) {
            .a => "𝐚𝐛𝐜𝐝𝐞𝐟𝐠𝐡𝐢𝐣𝐤𝐥𝐦𝐧𝐨𝐩𝐪𝐫𝐬𝐭𝐮𝐯𝐰𝐱𝐲𝐳",
            .A => "𝐀𝐁𝐂𝐃𝐄𝐅𝐆𝐇𝐈𝐉𝐊𝐋𝐌𝐍𝐎𝐏𝐐𝐑𝐒𝐓𝐔𝐕𝐖𝐗𝐘𝐙",
        },
        .double_struck => switch (base) {
            .a => "𝕒𝕓𝕔𝕕𝕖𝕗𝕘𝕙𝕚𝕛𝕜𝕝𝕞𝕟𝕠𝕡𝕢𝕣𝕤𝕥𝕦𝕧𝕨𝕩𝕪𝕫",
            .A => "𝔸𝔹ℂ.𝔻𝔼𝔽𝔾ℍ.𝕀𝕁𝕂𝕃𝕄ℕ.𝕆ℙ.ℚ.ℝ.𝕊𝕋𝕌𝕍𝕎𝕏𝕐ℤ.",
        },
        .script => switch (base) {
            .a => "𝒶𝒷𝒸𝒹ℯ.𝒻ℊ.𝒽𝒾𝒿𝓀𝓁𝓂𝓃ℴ.𝓅𝓆𝓇𝓈𝓉𝓊𝓋𝓌𝓍𝓎𝓏",
            .A => "𝒜ℬ.𝒞𝒟ℰ.ℱ.𝒢ℋ.ℐ.𝒥𝒦ℒ.ℳ.𝒩𝒪𝒫𝒬ℛ.𝒮𝒯𝒰𝒱𝒲𝒳𝒴𝒵",
        },
    };
    const slice = letters[4 * (char - @intFromEnum(base)) ..];
    // For 3-byte characters we put a period at the end. All others are 4-byte.
    return if (slice[3] == '.') slice[0..3] else slice[0..4];
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
    while (!scanner.eof()) {
        if (try math.render(writer, &scanner)) break;
    } else try math.renderEnd(writer);
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

test "prefix operator" {
    try expect("<math><mo form=\"prefix\">+</mo><mi>x</mi></math>", "+x", .@"inline");
    try expect("<math><mo form=\"prefix\">-</mo><mi>x</mi></math>", "-x", .@"inline");
    try expect("<math><mo form=\"prefix\">±</mo><mi>x</mi></math>", "\\pm x", .@"inline");
}

test "basic expression" {
    try expect("<math><mi>x</mi><mo>+</mo><mn>1</mn></math>", "x + 1", .@"inline");
}

test "text" {
    try expect("<math><mi>x</mi><mo>+</mo><mtext>one</mtext></math>", "x + \\text{one}", .@"inline");
}

test "delimiters" {
    try expect("<math><mo stretchy=\"false\">(</mo><mi>A</mi><mo stretchy=\"false\">)</mo></math>", "(A)", .@"inline");
    try expect("<math><mo>(</mo><mi>A</mi><mo>)</mo></math>", "\\left(A\\right)", .@"inline");
}

test "sqrt" {
    try expect("<math><msqrt><mn>2</mn></msqrt><mo>+</mo><msqrt><mi>x</mi><mi>y</mi></msqrt></math>", "\\sqrt2+\\sqrt{xy}", .@"inline");
}

test "phantom" {
    try expect("<math><mphantom><mi>x</mi></mphantom></math>", "\\phantom x", .@"inline");
}

test "fractions" {
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac12", .@"inline");
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac{1}{2}", .@"inline");
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac1{2}", .@"inline");
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac{1}2", .@"inline");
}

test "subscripts" {
    try expect("<math><msub><mi>a</mi><mn>1</mn></msub></math>", "a_1", .@"inline");
    try expect("<math><msub><mi>a</mi><mn>1</mn></msub><mn>2</mn></math>", "a_12", .@"inline");
    try expect("<math><msub><mi>a</mi><mn>12</mn></msub></math>", "a_{12}", .@"inline");
}

test "superscripts" {
    try expect("<math><msup><mi>a</mi><mn>1</mn></msup></math>", "a^1", .@"inline");
    try expect("<math><msup><mi>a</mi><mn>1</mn></msup><mn>2</mn></math>", "a^12", .@"inline");
    try expect("<math><msup><mi>a</mi><mn>12</mn></msup></math>", "a^{12}", .@"inline");
}

test "squared expression" {
    // It would be more correct to wrap the <msup> around the whole expression.
    // We could do so by buffering tokens in parens like we do for braces.
    // However, that could cause issues with unbalanced delimiters e.g. [1,5).
    // The lazy way looks the same, and sounds the same (with macOS VoiceOver).
    // MathJax and KaTeX do the lazy approach as well.
    try expect(
        "<math><mo stretchy=\"false\">(</mo><mi>x</mi><mo>+</mo><mi>y</mi><msup><mo stretchy=\"false\">)</mo><mn>2</mn></msup></math>",
        "(x+y)^2",
        .@"inline",
    );
}

test "vectors" {
    try expect("<math><mover><mi>x</mi><mo stretchy=\"false\">→</mo></mover></math>", "\\vec x", .@"inline");
    try expect("<math><mover><mi>x</mi><mo stretchy=\"false\">→</mo></mover></math>", "\\vec{x}", .@"inline");
}

test "boxed" {
    try expect("<math><mrow style=\"padding: 0.25em; border: 1px solid\"><mi>x</mi></mrow></math>", "\\boxed x", .@"inline");
    try expect("<math><mrow style=\"padding: 0.25em; border: 1px solid\"><mi>x</mi></mrow></math>", "\\boxed{x}", .@"inline");
}

test "variant characters" {
    try expect("<math><mi mathvariant=\"normal\">a</mi></math>", "\\mathrm a", .@"inline");
    try expect("<math><mi>𝐚</mi></math>", "\\mathbf a", .@"inline");
    try expect("<math><mi>𝕒</mi></math>", "\\mathbb a", .@"inline");
    try expect("<math><mi>𝒶</mi></math>", "\\mathcal a", .@"inline");
    try expect("<math><mi mathvariant=\"normal\">A</mi></math>", "\\mathrm A", .@"inline");
    try expect("<math><mi>𝐀</mi></math>", "\\mathbf A", .@"inline");
    try expect("<math><mi>𝔸</mi></math>", "\\mathbb A", .@"inline");
    try expect("<math><mi>𝒜</mi></math>", "\\mathcal A", .@"inline");
}

test "nested variant characters" {
    try expect(
        "<math><mi>𝐚</mi><mi>𝕒</mi><mi>𝐚</mi><mi>𝕫</mi><mi>𝐳</mi><mi>z</mi></math>",
        "\\mathbf{a\\mathbb{a\\mathbf{a}z}z}z",
        .@"inline",
    );
}

// test "mrows" {
//     try expect(
//         "<math><mfrac><mrow><mi>a</mi><mi>b</mi></mrow><mrow><mi>c</mi><mi>d</mi></mrow></mfrac></math>",
//         "\\frac{ab}{cd}",
//         .@"inline",
//     );
// }

// test "quadratic formula" {
//     try expect(
//         \\<math display="block">
//         \\<mi>x</mi>
//         \\<mo>=</mo>
//         \\<mo form="prefix">-</mo>
//         \\<mi>b</mi>
//         \\<mo>±</mo>
//         \\<mfrac>
//         \\<msqrt>
//         \\<msup>
//         \\<mi>b</mi>
//         \\<mn>2</mn>
//         \\</msup>
//         \\<mo>-</mo>
//         \\<mn>4</mn>
//         \\<mi>a</mi>
//         \\<mi>c</mi>
//         \\</msqrt>
//         \\<mrow>
//         \\<mn>2</mn>
//         \\<mi>a</mi>
//         \\</mrow>
//         \\</mfrac>
//         \\</math>
//     ,
//         \\x = -b \pm \frac{\sqrt{b^2 - 4ac}}{2a}
//     , .display);
// }
