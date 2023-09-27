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
stack: TagStack(Tag) = .{},
next_is_prefix: bool = true,
next_is_stretchy: bool = false,

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

// TODO reorder/reorganize these
const Token = union(enum) {
    // Special
    eof,
    @"\n",
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
    mi_normal: []const u8,
    mo: []const u8,
    mo_delimiter: []const u8,
    mo_prefix: []const u8,
    mo_postfix: []const u8,
    mspace: []const u8,
    // Other
    @"{",
    @"}",
    _,
    @"^",
    @"&",
    @"\\",
    stretchy,
    dot,
    colon_rel,
    colon_def,
    boxed,
    // This is [3:0]u8 instead of []const u8 to save space in the Tag type.
    accent: [3:0]u8,
    begin: Environment,
    end: Environment,
    variant: Variant,
};

const Environment = enum { matrix, bmatrix, cases };

const Variant = enum {
    normal,
    bold,
    double_struck,
    script,
};

fn getVariantLetter(char: u8, variant: Variant) ?[]const u8 {
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

fn lookupMacro(name: []const u8) ?Token {
    const list = .{
        // Special
        .{ "text", .mtext_start },
        .{ "begin", .{ .begin = undefined } },
        .{ "end", .{ .end = undefined } },
        .{ "frac", .mfrac },
        .{ "sqrt", .msqrt },
        .{ "colon", .colon_def },
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
        .{ "lvert", .{ .mo_prefix = "|" } },
        .{ "rvert", .{ .mo_postfix = "|" } },
        .{ "lVert", .{ .mo_delimiter = "‖" } },
        .{ "rVert", .{ .mo_delimiter = "‖" } },
        .{ "langle", .{ .mo_delimiter = "⟨" } },
        .{ "rangle", .{ .mo_delimiter = "⟩" } },
        // Accents
        .{ "vec", .{ .accent = "→".* } },
        .{ "hat", .{ .accent = "^\x00\x00".* } },
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
        .{ "coloneqq", .{ .mo = "≔" } },
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
        return switch (scanner.next() orelse return .eof) {
            inline '\n', '$', '{', '}', '_', '^', '&' => |char| {
                if (char == '_' or char == '^') self.args_left = 1;
                return @field(Token, &.{char});
            },
            'a'...'z', 'A'...'Z', '?' => .{ .mi = scanner.source[start..scanner.offset] },
            '+', '-', '=', '>', ',', ';', '/', '!' => .{ .mo = scanner.source[start..scanner.offset] },
            '.' => .dot,
            ':' => .colon_rel,
            '<' => .{ .mo = "&lt;" },
            '(', ')', '[', ']' => .{ .mo_delimiter = scanner.source[start..scanner.offset] },
            '0'...'9' => {
                if (consume_multiple_digits) while (scanner.peek()) |char| switch (char) {
                    '0'...'9', '.' => scanner.eat(),
                    else => break,
                };
                return .{ .mn = scanner.source[start..scanner.offset] };
            },
            "λ"[0] => if (scanner.consume("λ"[1])) .{ .mi = "λ" } else scanner.fail("unexpected UTF-8 sequence", .{}),
            '\\' => {
                const after_backslash = scanner.offset;
                if (scanner.consumeAny("\\;,{}")) |char| return switch (char) {
                    '\\' => .@"\\",
                    ';' => .{ .mspace = "0.278em" },
                    ',' => .{ .mspace = "0.1667em" },
                    '{', '}' => .{ .mo_delimiter = scanner.source[after_backslash..scanner.offset] },
                    else => unreachable,
                };
                while (scanner.peek()) |char| switch (char) {
                    'a'...'z', 'A'...'Z' => scanner.eat(),
                    else => break,
                };
                const name = scanner.source[after_backslash..scanner.offset];
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
                        environment.* = std.meta.stringToEnum(Environment, env_name) orelse
                            return scanner.failOn(env_name, "unknown environment", .{});
                    },
                    .variant => |variant| {
                        const open = scanner.consumeAny(" {") orelse return scanner.fail("expected space or '{{'", .{});
                        const text = scanner.consumeLength(1) orelse return scanner.fail("unexpected EOF", .{});
                        if (open == '{') try scanner.expect('}');
                        return switch (variant) {
                            .normal => .{ .mi_normal = text },
                            else => .{ .mi = getVariantLetter(text[0], variant) orelse return scanner.failOn(text, "invalid letter", .{}) },
                        };
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
    try expectTokens(&[_]Token{.eof}, "");
}

test "scan blank line" {
    try expectTokens(&[_]Token{ .@"\n", .eof }, "\n");
}

test "scan variable" {
    try expectTokens(&[_]Token{ .{ .mi = "x" }, .eof }, "x");
}

test "scan subscript" {
    try expectTokens(&[_]Token{
        .{ .mi = "x" },
        ._,
        .{ .mn = "1" },
        .{ .mn = "2345" },
        .eof,
    }, "x_12345");
}

test "scan fraction" {
    try expectTokens(&[_]Token{
        .mfrac,
        .{ .mn = "1" },
        .{ .mn = "2" },
        .{ .mn = "345" },
        .eof,
    }, "\\frac12345");
}

test "scan text" {
    try expectTokens(&[_]Token{
        .{ .mi = "x" },
        .{ .mo = "+" },
        .mtext_start,
        .{ .mtext_content = "some stuff" },
        .@"\n",
        .{ .mtext_content = "more here" },
        .mtext_end,
        .{ .mo = "-" },
        .{ .mi = "y" },
        .eof,
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
        .eof,
    },
        \\x = -b \pm \frac{\sqrt{b^2 - 4ac}}{2a}
    );
}

// TODO reorder/reorganize these
const Tag = union(enum) {
    math,
    mrow,
    mrow_elide,
    mfrac,
    mfrac_arg,
    msqrt,
    mphantom,
    msub,
    msup,
    mtext,
    munder,
    mover,
    munderover,
    munderover_arg,
    mtable,
    mtr,
    mtd,
    boxed,
    accent: [3:0]u8,

    fn isArg(self: Tag) bool {
        return switch (self) {
            .mfrac_arg, .munderover_arg => true,
            else => false,
        };
    }

    fn hasImplicitMrow(self: Tag) bool {
        return switch (self) {
            .math, .mtext, .mover, .mtable, .mtr => unreachable,
            .mrow, .mrow_elide, .msqrt, .mphantom, .boxed, .mtd => true,
            .mfrac, .mfrac_arg, .msub, .msup, .munder, .munderover, .munderover_arg, .accent => false,
        };
    }

    pub fn writeOpenTag(self: Tag, writer: anytype) !void {
        switch (self) {
            .math => unreachable,
            .mrow_elide, .mfrac_arg, .munderover_arg, .accent => {},
            // TODO consider CSS classs instead
            .boxed => try writer.writeAll("<mrow style=\"padding: 0.25em; border: 1px solid\">"),
            else => try fmt.format(writer, "<{s}>", .{@tagName(self)}),
        }
    }

    pub fn writeCloseTag(self: Tag, writer: anytype) !void {
        switch (self) {
            .math => unreachable,
            .mrow_elide, .mfrac_arg, .munderover_arg => {},
            .accent => |text| if (text[0] == "→"[0]) // TODO fix
                try fmt.format(writer, "<mo stretchy=\"false\" lspace=\"0\" rspace=\"0\">{s}</mo>", .{@as([*:0]const u8, &text)})
            else
                try fmt.format(writer, "<mo stretchy=\"false\">{s}</mo>", .{@as([*:0]const u8, &text)}),
            .boxed => try writer.writeAll("</mrow>"),
            else => try fmt.format(writer, "</{s}>", .{@tagName(self)}),
        }
    }
};

fn top(self: MathML) Tag {
    return self.stack.top() orelse .math;
}

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
    while (true) switch (try self.tokenizer.next(scanner)) {
        .eof => return false,
        .@"\n" => {
            try writer.writeByte('\n');
            return false;
        },
        .@"$" => {
            if (self.kind == .display) try scanner.expect('$');
            try self.renderEnd(writer);
            return true;
        },
        else => |token| try self.renderToken(writer, scanner, token),
    };
}

fn renderEnd(self: *MathML, writer: anytype) !void {
    _ = self;
    // TODO: check stack and buffer
    try writer.writeAll("</math>");
}

fn renderToken(self: *MathML, writer: anytype, scanner: *Scanner, token: Token) !void {
    const prefix = self.next_is_prefix;
    const stretchy = self.next_is_stretchy;
    self.next_is_prefix = (token == .mo and token.mo[0] != '!') or token == .@"&" or token == .@"\\";
    self.next_is_stretchy = token == .stretchy;
    if (token == .@"}") switch (self.top()) {
        .mrow, .mrow_elide => try self.stack.pop(writer),
        else => return scanner.failAtOffset(scanner.offset - 1, "unexpected '}}'", .{}),
    };
    const original_stack_len = self.stack.len();
    if (scanner.peek()) |char| switch (char) {
        '_' => try if (token == .mo and std.mem.eql(u8, token.mo, "∑"))
            self.stack.append(writer, .{ .munderover, .munderover_arg })
        else if (token == .mi and std.mem.eql(u8, token.mi, "lim"))
            self.stack.append(writer, .{.munder})
        else
            self.stack.push(writer, .msub),
        '^' => if (self.top() != .munderover_arg) try self.stack.push(writer, .msup),
        else => {},
    };
    switch (token) {
        .eof, .@"\n", .@"$", .variant => unreachable,
        ._, .@"^", .stretchy => return,
        .@"{" => try self.stack.push(writer, try self.tagForOpenBrace(scanner)),
        .@"}" => {},
        .mfrac => try self.stack.append(writer, .{ .mfrac, .mfrac_arg }),
        .msqrt => try self.stack.push(writer, .msqrt),
        .mphantom => try self.stack.push(writer, .mphantom),
        .boxed => try self.stack.push(writer, .boxed),
        .mtext_start => return self.stack.push(writer, .mtext),
        .mtext_content => |text| return writer.writeAll(text),
        .mtext_end => try self.stack.popTag(writer, .mtext),
        .mn => |text| try fmt.format(writer, "<mn>{s}</mn>", .{text}),
        .mi => |text| try fmt.format(writer, "<mi>{s}</mi>", .{text}),
        .mi_normal => |text| try fmt.format(writer, "<mi mathvariant=\"normal\">{s}</mi>", .{text}),
        // TODO generalize into list of plus, minus, ...
        .mo => |text| try if (prefix and (text[0] == '+' or text[0] == '-' or std.mem.eql(u8, text, "±")))
            fmt.format(writer, "<mo form=\"prefix\">{s}</mo>", .{text})
        else if (self.stack.len() >= 2 and (self.stack.get(self.stack.len() - 2) == .munder or self.stack.get(self.stack.len() - 2) == .munderover_arg))
            fmt.format(writer, "<mo lspace=\"0\" rspace=\"0\">{s}</mo>", .{text})
        else
            fmt.format(writer, "<mo>{s}</mo>", .{text}),
        .mo_delimiter => |text| try if (stretchy)
            fmt.format(writer, "<mo>{s}</mo>", .{text})
        else
            fmt.format(writer, "<mo stretchy=\"false\">{s}</mo>", .{text}),
        .mo_prefix => |text| try fmt.format(writer, "<mo stretchy=\"false\" form=\"prefix\">{s}</mo>", .{text}),
        .mo_postfix => |text| try fmt.format(writer, "<mo stretchy=\"false\" form=\"postfix\">{s}</mo>", .{text}),
        .dot => try writer.writeAll("<mo lspace=\"0\" rspace=\"0\">.</mo>"),
        .colon_def => try writer.writeAll("<mo rspace=\"0.278em\">:</mo>"),
        .colon_rel => try writer.writeAll("<mo lspace=\"0.278em\" rspace=\"0.278em\">:</mo>"),
        .mspace => |width| try fmt.format(writer, "<mspace width=\"{s}\"/>", .{width}),
        .accent => |text| try self.stack.append(writer, .{ .mover, .{ .accent = text } }),
        .begin => |environment| {
            switch (environment) {
                .matrix => {},
                .bmatrix => try writer.writeAll("<mo>[</mo>"),
                .cases => try writer.writeAll("<mo>{</mo>"),
            }
            try self.stack.append(writer, .{ .mtable, .mtr, .mtd });
        },
        .end => |environment| {
            switch (self.top()) {
                .mtd => {
                    // TODO maybe don't need to represent all in stack.
                    try self.stack.popTag(writer, .mtd);
                    try self.stack.popTag(writer, .mtr);
                    try self.stack.popTag(writer, .mtable);
                },
                else => return scanner.fail("FIXME unclosed", .{}),
            }
            switch (environment) {
                .matrix, .cases => {},
                .bmatrix => try writer.writeAll("<mo>]</mo>"),
            }
        },
        .@"&" => switch (self.top()) {
            .mtd => {
                try self.stack.popTag(writer, .mtd);
                try self.stack.push(writer, .mtd);
            },
            else => return scanner.fail("FIXME unclosed", .{}),
        },
        .@"\\" => switch (self.top()) {
            .mtd => {
                try self.stack.popTag(writer, .mtd);
                try self.stack.popTag(writer, .mtr);
                try self.stack.append(writer, .{ .mtr, .mtd });
            },
            else => return scanner.fail("FIXME unclosed", .{}),
        },
    }
    if (self.stack.len() <= original_stack_len) while (self.stack.top()) |tag| switch (tag) {
        .mrow, .mrow_elide, .mtd => break,
        else => {
            try self.stack.popTag(writer, tag);
            if (tag.isArg()) break;
        },
    };
}

fn tagForOpenBrace(self: MathML, scanner: *Scanner) !Tag {
    if (self.top().hasImplicitMrow()) return .mrow_elide;
    const start = scanner.offset;
    defer scanner.offset = start;
    var tokenizer = self.tokenizer;
    const first = try tokenizer.next(scanner);
    if (first == .@"{" or first == .@"}")
        return scanner.failOn(scanner.source[start..scanner.offset], "unexpected character", .{});
    var depth: usize = 1;
    const second = switch (try tokenizer.next(scanner)) {
        .@"{" => while (true) switch (try tokenizer.next(scanner)) {
            .eof, .@"$" => return .mrow,
            .@"{" => depth += 1,
            .@"}" => {
                depth -= 1;
                if (depth == 0) break try tokenizer.next(scanner);
            },
            else => {},
        },
        else => |token| token,
    };
    return if (second == .@"}") .mrow_elide else .mrow;
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

fn expectFailure(expected_message: []const u8, source: []const u8, kind: Kind) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var math = try init(std.io.null_writer, kind);
    const result = while (!scanner.eof()) {
        if (math.render(std.io.null_writer, &scanner) catch |err| break err) break;
    } else math.renderEnd(std.io.null_writer);
    try reporter.expectFailure(expected_message, result);
}

test "empty input" {
    try expect("<math></math>", "", .@"inline");
    try expect("<math display=\"block\"></math>", "", .display);
}

test "newlines passed through" {
    try expect("<math>\n\n</math>", "\n\n", .@"inline");
    try expect("<math display=\"block\">\n\n</math>", "\n\n", .display);
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

test "entities" {
    try expect("<math><mn>1</mn><mo>&lt;</mo><mi>x</mi><mo>></mo><mn>1</mn></math>", "1<x>1", .@"inline");
}

test "text" {
    try expect("<math><mi>x</mi><mo>+</mo><mtext>one</mtext></math>", "x + \\text{one}", .@"inline");
}

test "symbols" {
    try expect("<math><mi>α</mi><mi>ω</mi></math>", "\\alpha\\omega", .@"inline");
}

test "lambda" {
    // I support λ because I use it a lot in intro-lambda.md.
    try expect("<math><mi>λ</mi><mi>λ</mi></math>", "\\lambdaλ", .@"inline");
}

test "delimiters" {
    try expect("<math><mo stretchy=\"false\">(</mo><mi>A</mi><mo stretchy=\"false\">)</mo></math>", "(A)", .@"inline");
    try expect("<math><mo>(</mo><mi>A</mi><mo>)</mo></math>", "\\left(A\\right)", .@"inline");
}

test "sqrt" {
    try expect(
        "<math><msqrt><mn>2</mn></msqrt><mo>+</mo><msqrt><mi>x</mi><mi>y</mi></msqrt></math>",
        "\\sqrt2+\\sqrt{xy}",
        .@"inline",
    );
}

test "spacing" {
    try expect("<math><mspace width=\"1em\"/></math>", "\\quad", .@"inline");
    try expect("<math><mspace width=\"0.278em\"/></math>", "\\;", .@"inline");
    try expect("<math><mspace width=\"0.1667em\"/></math>", "\\,", .@"inline");
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

test "R squared" {
    try expect("<math><msup><mi>ℝ</mi><mn>2</mn></msup></math>", "\\mathbb{R}^2", .@"inline");
}

test "squared expression" {
    // It would be more correct to wrap the <msup> around the whole expression,
    // but it's much easier to just wrap around the closing paren. This renders
    // the same, and even sounds the same on macOS VoiceOver. MathJax and KaTeX
    // take this lazy approach as well.
    try expect(
        \\<math><mo stretchy="false">(</mo><mi>x</mi><mo>+</mo><mi>y</mi>
        ++
        \\<msup><mo stretchy="false">)</mo><mn>2</mn></msup></math>
    , "(x+y)^2", .@"inline");
}

test "vectors" {
    try expect("<math><mover><mi>x</mi><mo stretchy=\"false\">→</mo></mover></math>", "\\vec x", .@"inline");
    try expect("<math><mover><mi>x</mi><mo stretchy=\"false\">→</mo></mover></math>", "\\vec{x}", .@"inline");
    try expect("<math><mover><mrow><mi>P</mi><mi>Q</mi></mrow><mo stretchy=\"false\">→</mo></mover></math>", "\\vec{PQ}", .@"inline");
}

test "boxed" {
    try expect("<math><mrow style=\"padding: 0.25em; border: 1px solid\"><mi>x</mi></mrow></math>", "\\boxed x", .@"inline");
    try expect("<math><mrow style=\"padding: 0.25em; border: 1px solid\"><mi>x</mi></mrow></math>", "\\boxed{x}", .@"inline");
}

test "set with braces" {
    try expect(
        "<math><mo stretchy=\"false\">{</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo stretchy=\"false\">}</mo></math>",
        "\\{1,2\\}",
        .@"inline",
    );
}

test "limit" {
    try expect(
        "<math><munder><mi>lim</mi><mrow><mi>x</mi><mo>→</mo><mi>∞</mi></mrow></munder><mi>x</mi></math>",
        "\\lim_{x\\to\\infty}x",
        .@"inline",
    );
}

test "summation" {
    try expect("<math><munderover><mo>∑</mo><mi>a</mi><mi>b</mi></munderover></math>", "\\sum_a^b", .@"inline");
}

test "summation equation" {
    try expect(
        \\<math><munderover><mo>∑</mo>
        \\<mrow><mi>k</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover>
        \\<mi>k</mi><mo>=</mo><mfrac><mrow><mi>k</mi>
        \\<mo stretchy="false">(</mo><mi>k</mi><mo>+</mo><mn>1</mn><mo stretchy="false">)</mo>
        \\</mrow><mn>2</mn></mfrac></math>
    ,
        "\\sum_ \n {k=1}^n \n k=\\frac{k \n (k+1) \n }2",
        .@"inline",
    );
}

test "variant characters" {
    try expect("<math><mi mathvariant=\"normal\">a</mi></math>", "\\mathrm a", .@"inline");
    try expect("<math><mi>𝐚</mi></math>", "\\mathbf a", .@"inline");
    try expect("<math><mi>𝕒</mi></math>", "\\mathbb a", .@"inline");
    try expect("<math><mi>𝒶</mi></math>", "\\mathcal a", .@"inline");

    try expect("<math><mi mathvariant=\"normal\">z</mi></math>", "\\mathrm{z}", .@"inline");
    try expect("<math><mi>𝐳</mi></math>", "\\mathbf{z}", .@"inline");
    try expect("<math><mi>𝕫</mi></math>", "\\mathbb{z}", .@"inline");
    try expect("<math><mi>𝓏</mi></math>", "\\mathcal{z}", .@"inline");

    try expect("<math><mi mathvariant=\"normal\">A</mi></math>", "\\mathrm A", .@"inline");
    try expect("<math><mi>𝐀</mi></math>", "\\mathbf A", .@"inline");
    try expect("<math><mi>𝔸</mi></math>", "\\mathbb A", .@"inline");
    try expect("<math><mi>𝒜</mi></math>", "\\mathcal A", .@"inline");

    try expect("<math><mi mathvariant=\"normal\">Z</mi></math>", "\\mathrm{Z}", .@"inline");
    try expect("<math><mi>𝐙</mi></math>", "\\mathbf{Z}", .@"inline");
    try expect("<math><mi>ℤ</mi></math>", "\\mathbb{Z}", .@"inline");
    try expect("<math><mi>𝒵</mi></math>", "\\mathcal{Z}", .@"inline");
}

test "mrows" {
    try expect(
        "<math><mfrac><mrow><mi>a</mi><mi>b</mi></mrow><mrow><mi>c</mi><mi>d</mi></mrow></mfrac></math>",
        "\\frac{ab}{cd}",
        .@"inline",
    );
}

test "quadratic formula" {
    try expect(
        \\<math display="block"><mi>x</mi><mo>=</mo><mo form="prefix">-</mo><mi>b</mi>
        ++
        \\<mo>±</mo><mfrac><msqrt><msup><mi>b</mi><mn>2</mn></msup><mo>-</mo>
        ++
        \\<mn>4</mn><mi>a</mi><mi>c</mi></msqrt><mrow><mn>2</mn><mi>a</mi></mrow></mfrac></math>
    ,
        \\x = -b \pm \frac{\sqrt{b^2 - 4 a c}}{2 a}
    , .display);
}

test "matrix environment" {
    try expect(
        \\<math display="block"><mtable><mtr><mtd>
        \\<mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd>
        \\<mi>c</mi></mtd><mtd><mi>d</mi>
        \\</mtd></mtr></mtable></math>
    ,
        \\\begin{matrix}
        \\a & b \\
        \\c & d
        \\\end{matrix}
    , .display);
}

test "bmatrix environment" {
    try expect(
        "<math><mo>[</mo><mtable><mtr><mtd><mi>x</mi></mtd></mtr></mtable><mo>]</mo></math>",
        "\\begin{bmatrix}x\\end{bmatrix}",
        .@"inline",
    );
}

test "cases environment" {
    try expect(
        \\<math><mi>f</mi><mo stretchy="false">(</mo><mi>x</mi><mo stretchy="false">)</mo><mo>=</mo>
        \\<mo>{</mo><mtable><mtr><mtd>
        \\<mn>1</mn></mtd><mtd><mtext>if</mtext><mspace width="0.278em"/><mi>x</mi><mo>></mo><mn>0</mn></mtd></mtr><mtr><mtd>
        \\<mn>0</mn></mtd><mtd><mtext>if</mtext><mspace width="0.278em"/><mi>x</mi><mo>=</mo><mn>0</mn></mtd></mtr><mtr><mtd>
        \\<mo form="prefix">-</mo><mn>1</mn></mtd><mtd><mtext>if</mtext><mspace width="0.278em"/><mi>x</mi><mo>&lt;</mo><mn>0</mn>
        \\</mtd></mtr></mtable></math>
    ,
        \\f(x)=
        \\\begin{cases}
        \\1 & \text{if}\; x > 0 \\
        \\0 & \text{if}\; x = 0 \\
        \\-1 & \text{if}\; x < 0
        \\\end{cases}
    , .@"inline");
}

test "missing macro name" {
    try expectFailure("<input>:1:6: expected a macro name", "1 + \\", .@"inline");
}

test "invalid macro name" {
    try expectFailure("<input>:1:2: \"foo\": unknown macro", "\\foo", .@"inline");
}

test "invalid variant letter" {
    try expectFailure("<input>:1:9: \"0\": invalid letter", "\\mathbf{0}", .@"inline");
}

test "invalid character" {
    try expectFailure("<input>:1:1: \"#\": unexpected character", "#", .@"inline");
}

test "invalid close brace" {
    try expectFailure("<input>:1:1: unexpected '}'", "}", .@"inline");
}

test "invalid empty braces" {
    try expectFailure("<input>:1:7: \"}\": unexpected character", "\\frac{}", .@"inline");
}

// TODO invalid end doesn't match begin env
