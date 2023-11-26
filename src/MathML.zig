// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module renders a subset of TeX to MathML.
//! It scans input until a closing "$" or "$$" delimiter, and it yields control
//! when it encounters a newline, so it can be used by the Markdown renderer.

const std = @import("std");
const tag_stack = @import("tag_stack.zig");
const testing = std.testing;
const assert = std.debug.assert;
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const TagStack = tag_stack.TagStack;
const MathML = @This();

options: Options,
tokenizer: Tokenizer = .{},
stack: TagStack(Tag) = .{},
next_is_prefix: bool = true,
next_is_infix: bool = false,
next_is_stretchy: bool = false,

pub const Options = struct { block: bool = false };

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
    mo_closed: []const u8,
    mo_closed_always: []const u8,
    mspace: []const u8,
    // Other
    @"{",
    @"}",
    _,
    @"^",
    @"&",
    @"\\",
    stretchy,
    colon_rel,
    colon_def,
    boxed,
    // This is [3:0]u8 instead of []const u8 to save space in the Tag type.
    accent: [3:0]u8,
    begin: Environment,
    end: Environment,
    variant: Variant,
};

const spacing = struct {
    const quad = "1em";
    const thick = "0.278em";
    const thin = "0.1667em";
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
        .{ "quad", .{ .mspace = spacing.quad } },
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
        .{ "lVert", .{ .mo_prefix = "‖" } },
        .{ "rVert", .{ .mo_postfix = "‖" } },
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
        .{ "ast", .{ .mo_closed = "∗" } },
        .{ "bullet", .{ .mo_closed = "∙" } },
        .{ "cdot", .{ .mo = "⋅" } },
        .{ "coloneqq", .{ .mo = "≔" } },
        .{ "cup", .{ .mo = "∪" } },
        .{ "ge", .{ .mo = "≥" } },
        .{ "in", .{ .mo = "∈" } },
        .{ "le", .{ .mo = "≤" } },
        .{ "mapsto", .{ .mo = "↦" } },
        .{ "ne", .{ .mo = "≠" } },
        .{ "notin", .{ .mo = "∉" } },
        .{ "odot", .{ .mo_closed = "⊙" } },
        .{ "oplus", .{ .mo_closed = "⊕" } },
        .{ "pm", .{ .mo = "±" } },
        .{ "setminus", .{ .mo = "∖" } },
        .{ "subseteq", .{ .mo = "⊆" } },
        .{ "sum", .{ .mo = "∑" } },
        .{ "times", .{ .mo = "×" } },
        .{ "to", .{ .mo = "→" } },
    };
    return std.ComptimeStringMap(Token, list).get(name);
}

fn lookupUnicode(bytes: []const u8) ?Token {
    const Kind = enum { mi, mo };
    const list = .{
        // Letters
        .{ "ℵ", .mi },
        .{ "α", .mi },
        .{ "χ", .mi },
        .{ "ϵ", .mi },
        .{ "γ", .mi },
        .{ "λ", .mi },
        .{ "μ", .mi },
        .{ "ω", .mi },
        // Symbols
        .{ "…", .mi },
        .{ "∞", .mi },
        // Operators
        .{ "±", .mo },
        .{ "×", .mo },
        .{ "≠", .mo },
        .{ "≤", .mo },
        .{ "≥", .mo },
        .{ "∈", .mo },
        .{ "∉", .mo },
        .{ "⊆", .mo },
    };
    return switch (std.ComptimeStringMap(Kind, list).get(bytes) orelse return null) {
        inline else => |kind| @unionInit(Token, @tagName(kind), bytes),
    };
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
            '+', '=', '>', ',', ';', '!' => .{ .mo = scanner.source[start..scanner.offset] },
            // Convert ASCII hyphen-minus to a Unicode minus sign. We shouldn't need to:
            // "MathML renderers should treat U+002D HYPHEN-MINUS as equivalent to U+2212 MINUS SIGN
            // in formula contexts such as `mo`" (https://www.w3.org/TR/MathML/chapter7.html).
            // But Chrome doesn't seem to respect this.
            '-' => .{ .mo = "−" },
            '.', '/' => .{ .mo_closed_always = scanner.source[start..scanner.offset] },
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
            '\\' => {
                const after_backslash = scanner.offset;
                if (scanner.consumeAny("\\;,{}")) |char| return switch (char) {
                    '\\' => .@"\\",
                    ';' => .{ .mspace = spacing.thick },
                    ',' => .{ .mspace = spacing.thin },
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
            else => |char| {
                const span = scanner.source[start..scanner.offset];
                scanner.uneat();
                return switch (std.unicode.utf8ByteSequenceLength(char) catch |err| switch (err) {
                    error.Utf8InvalidStartByte => return scanner.failOn(span, "invalid UTF-8 byte", .{}),
                }) {
                    0 => unreachable,
                    1 => scanner.failOn(span, "unexpected character", .{}),
                    else => |len| if (scanner.consumeLength(len)) |bytes|
                        lookupUnicode(bytes) orelse scanner.failOn(bytes, "unexpected UTF-8 sequence", .{})
                    else
                        scanner.failOn(span, "expected {} byte UTF-8 sequence", .{len}),
                };
            },
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
        .{ .mo = "−" },
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
        .{ .mo = "−" },
        .{ .mi = "b" },
        .{ .mo = "±" },
        .mfrac,
        .@"{",
        .msqrt,
        .@"{",
        .{ .mi = "b" },
        .@"^",
        .{ .mn = "2" },
        .{ .mo = "−" },
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

    environment: Environment,
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
            .mtext,
            .mover,
            => unreachable,
            .mrow, .mrow_elide, .msqrt, .mphantom, .environment, .boxed => true,
            .math, .mfrac, .mfrac_arg, .msub, .msup, .munder, .munderover, .munderover_arg, .accent => false,
        };
    }

    fn formatFn(self: Tag, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try switch (self) {
            .math => unreachable,
            .environment => |environment| writer.print("{s} environment", .{@tagName(environment)}),
            .mrow_elide => writer.writeAll("<mrow> tag"),
            else => writer.print("<{s}> tag", .{@tagName(self)}),
        };
    }

    fn format(self: Tag) std.fmt.Formatter(formatFn) {
        return .{ .data = self };
    }

    pub fn writeOpenTag(self: Tag, writer: anytype) !void {
        switch (self) {
            .math => unreachable,
            .mrow_elide, .mfrac_arg, .munderover_arg, .accent => {},
            // TODO consider CSS classs instead (or not: bad for rss)
            .boxed => try writer.writeAll("<mrow style=\"padding: 0.25em; border: 1px solid\">"),
            .environment => |environment| try writer.writeAll(switch (environment) {
                .matrix => "<mtable><mtr><mtd>",
                // Add an mrow otherwise Firefox doesn't stretch the bracket.
                // Should really do this for all stretchy (doesn't matter right
                // now because I'm not using \left and \right anywhere).
                .bmatrix => "<mrow><mo>[</mo><mtable><mtr><mtd>",
                .cases => "<mrow><mo>{</mo><mtable><mtr><mtd>",
            }),
            else => try writer.print("<{s}>", .{@tagName(self)}),
        }
    }

    pub fn writeCloseTag(self: Tag, writer: anytype) !void {
        switch (self) {
            .math => unreachable,
            .mrow_elide,
            .mfrac_arg,
            .munderover_arg,
            => {},
            .accent => |text| if (text[0] == "→"[0]) // TODO! fix
                try writer.print("<mo stretchy=\"false\" lspace=\"0\" rspace=\"0\">{s}</mo>", .{@as([*:0]const u8, &text)})
            else
                try writer.print("<mo stretchy=\"false\">{s}</mo>", .{@as([*:0]const u8, &text)}),
            .boxed => try writer.writeAll("</mrow>"),
            .environment => |environment| try writer.writeAll(switch (environment) {
                .matrix => "</mtd></mtr></mtable>",
                .bmatrix => "</mtd></mtr></mtable><mo>]</mo></mrow>",
                .cases => "</mtd></mtr></mtable></mrow>",
            }),
            else => try writer.print("</{s}>", .{@tagName(self)}),
        }
    }
};

fn top(self: MathML) Tag {
    return self.stack.top() orelse .math;
}

pub fn delimiter(self: MathML) []const u8 {
    return if (self.options.block) "$$" else "$";
}

pub fn render(writer: anytype, scanner: *Scanner, options: Options) !?MathML {
    try writer.writeAll(if (options.block) "<math display=\"block\">" else "<math>");
    var math = MathML{ .options = options };
    return if (!scanner.eof() and try math.@"resume"(writer, scanner)) null else math;
}

// TODO(https://github.com/ziglang/zig/issues/6025): Use async.
pub fn @"resume"(self: *MathML, writer: anytype, scanner: *Scanner) !bool {
    assert(!scanner.eof());
    while (true) switch (try self.tokenizer.next(scanner)) {
        .eof => return false,
        .@"\n" => {
            try writer.writeByte('\n');
            return false;
        },
        .@"$" => {
            if (self.options.block) try scanner.expect('$');
            if (scanner.consumeAny(",.!?:;")) |char| try writer.print("<mtext>{c}</mtext>", .{char});
            try self.renderEnd(writer, scanner);
            return true;
        },
        else => |token| self.renderToken(writer, scanner, token) catch |err| switch (err) {
            error.ExceededMaxTagDepth => return scanner.fail("exceeded maximum tag depth ({})", .{tag_stack.max_depth}),
            else => return err,
        },
    };
}

fn renderEnd(self: *MathML, writer: anytype, scanner: *Scanner) !void {
    if (self.stack.top()) |tag| return scanner.fail("unclosed {}", .{tag.format()});
    try writer.writeAll("</math>");
    self.* = undefined;
}

fn renderToken(self: *MathML, writer: anytype, scanner: *Scanner, token: Token) !void {
    const prefix = self.next_is_prefix;
    const infix = self.next_is_infix;
    const stretchy = self.next_is_stretchy;
    self.next_is_prefix = (token == .mo and token.mo[0] != '!') or token == .@"&" or token == .@"\\";
    self.next_is_infix = token == .mi or (token == .mo_delimiter and token.mo_delimiter[0] == ')');
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
        .mn => |text| try writer.print("<mn>{s}</mn>", .{text}),
        .mi => |text| try writer.print("<mi>{s}</mi>", .{text}),
        .mi_normal => |text| try writer.print("<mi mathvariant=\"normal\">{s}</mi>", .{text}),
        // TODO! generalize into list of plus, minus, ...
        .mo => |text| try if (prefix and (text[0] == '+' or std.mem.eql(u8, text, "−") or std.mem.eql(u8, text, "±")))
            writer.print("<mo form=\"prefix\">{s}</mo>", .{text})
        else if ((self.stack.len() >= 2 and (self.stack.get(self.stack.len() - 2) == .munder or self.stack.get(self.stack.len() - 2) == .munderover_arg)) or
            (prefix and std.mem.eql(u8, text, "×")))
            writer.print("<mo lspace=\"0\" rspace=\"0\">{s}</mo>", .{text})
        else
            writer.print("<mo>{s}</mo>", .{text}),
        .mo_delimiter => |text| try if (stretchy)
            writer.print("<mo>{s}</mo>", .{text})
        else
            writer.print("<mo stretchy=\"false\">{s}</mo>", .{text}),
        .mo_prefix => |text| try writer.print("<mo stretchy=\"false\" form=\"prefix\">{s}</mo>", .{text}),
        .mo_postfix => |text| try writer.print("<mo stretchy=\"false\" form=\"postfix\">{s}</mo>", .{text}),
        .mo_closed => |text| if (infix)
            try writer.print("<mo>{s}</mo>", .{text})
        else
            try writer.print("<mo lspace=\"0\" rspace=\"0\">{s}</mo>", .{text}),
        .mo_closed_always => |text| try writer.print("<mo lspace=\"0\" rspace=\"0\">{s}</mo>", .{text}),
        .colon_def => try writer.print("<mo rspace=\"{s}\">:</mo>", .{spacing.thick}),
        .colon_rel => try writer.print("<mo lspace=\"{0s}\" rspace=\"{0s}\">:</mo>", .{spacing.thick}),
        .mspace => |width| try writer.print("<mspace width=\"{s}\"/>", .{width}),
        .accent => |text| try self.stack.append(writer, .{ .mover, .{ .accent = text } }),
        .begin => |environment| try self.stack.push(writer, .{ .environment = environment }),
        .end => |environment| switch (self.top()) {
            .environment => |begin| if (environment == begin)
                try self.stack.pop(writer)
            else
                return scanner.fail("expected \\end{{{s}}}", .{@tagName(begin)}),
            else => return scanner.fail("unexpected end environment", .{}),
        },
        .@"&" => switch (self.top()) {
            .environment => try writer.writeAll("</mtd><mtd>"),
            else => return scanner.fail("unexpected &", .{}),
        },
        .@"\\" => switch (self.top()) {
            .environment => try writer.writeAll("</mtd></mtr><mtr><mtd>"),
            else => return scanner.fail("unexpected \\\\", .{}),
        },
    }
    if (self.stack.len() <= original_stack_len) while (self.stack.top()) |tag| switch (tag) {
        .mrow, .mrow_elide, .environment => break,
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

fn renderForTest(writer: anytype, scanner: *Scanner, options: Options) !void {
    var result = try render(writer, scanner, options);
    if (result) |*math| while (!scanner.eof()) {
        if (try math.@"resume"(writer, scanner)) break;
    } else try math.renderEnd(writer, scanner);
}

fn expect(expected_mathml: []const u8, source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    errdefer |err| reporter.showMessage(err);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    var actual_mathml = std.ArrayList(u8).init(allocator);
    try renderForTest(actual_mathml.writer(), &scanner, options);
    try testing.expectEqualStrings(expected_mathml, actual_mathml.items);
}

fn expectFailure(expected_message: []const u8, source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var reporter = Reporter.init(allocator);
    var scanner = Scanner{ .source = source, .reporter = &reporter };
    try reporter.expectFailure(expected_message, renderForTest(std.io.null_writer, &scanner, options));
}

test "empty input" {
    try expect("<math></math>", "", .{});
    try expect("<math display=\"block\"></math>", "", .{ .block = true });
}

test "newlines passed through" {
    try expect("<math>\n\n</math>", "\n\n", .{});
    try expect("<math display=\"block\">\n\n</math>", "\n\n", .{ .block = true });
}

test "variable" {
    try expect("<math><mi>x</mi></math>", "x", .{});
    try expect("<math display=\"block\"><mi>x</mi></math>", "x", .{ .block = true });
}

test "prefix operator" {
    try expect("<math><mo form=\"prefix\">+</mo><mi>x</mi></math>", "+x", .{});
    try expect("<math><mo form=\"prefix\">−</mo><mi>x</mi></math>", "-x", .{});
    try expect("<math><mo form=\"prefix\">±</mo><mi>x</mi></math>", "\\pm x", .{});
}

test "operators as values" {
    try expect(
        "<math><mo stretchy=\"false\">(</mo><mi>ℤ</mi><mo>,</mo>" ++
            "<mo form=\"prefix\">+</mo><mo>,</mo><mo lspace=\"0\" rspace=\"0\">×</mo>" ++
            "<mo stretchy=\"false\">)</mo></math>",
        "(\\mathbb{Z},+,\\times)",
        .{},
    );
}

test "basic expression" {
    try expect("<math><mi>x</mi><mo>+</mo><mn>1</mn></math>", "x + 1", .{});
}

test "entities" {
    try expect("<math><mn>1</mn><mo>&lt;</mo><mi>x</mi><mo>></mo><mn>1</mn></math>", "1<x>1", .{});
}

test "text" {
    try expect("<math><mi>x</mi><mo>+</mo><mtext>one</mtext></math>", "x + \\text{one}", .{});
}

test "symbols" {
    try expect("<math><mi>α</mi><mi>ω</mi></math>", "\\alpha\\omega", .{});
}

test "Unicode symbols" {
    try expect(
        \\<math><mi>ℵ</mi><mi>ℵ</mi>
        \\<mi>α</mi><mi>α</mi>
        \\<mi>χ</mi><mi>χ</mi>
        \\<mi>ϵ</mi><mi>ϵ</mi>
        \\<mi>γ</mi><mi>γ</mi>
        \\<mi>λ</mi><mi>λ</mi>
        \\<mi>μ</mi><mi>μ</mi>
        \\<mi>ω</mi><mi>ω</mi>
        \\<mi>…</mi><mi>…</mi>
        \\<mi>∞</mi><mi>∞</mi>
        \\<mo>±</mo><mo form="prefix">±</mo>
        \\<mo lspace="0" rspace="0">×</mo><mo lspace="0" rspace="0">×</mo>
        \\<mo>≠</mo><mo>≠</mo>
        \\<mo>≤</mo><mo>≤</mo>
        \\<mo>≥</mo><mo>≥</mo>
        \\<mo>∈</mo><mo>∈</mo>
        \\<mo>∉</mo><mo>∉</mo>
        \\<mo>⊆</mo><mo>⊆</mo></math>
    ,
        \\ℵ\aleph
        \\α\alpha
        \\χ\chi
        \\ϵ\epsilon
        \\γ\gamma
        \\λ\lambda
        \\μ\mu
        \\ω\omega
        \\…\dots
        \\∞\infty
        \\±\pm
        \\×\times
        \\≠\ne
        \\≤\le
        \\≥\ge
        \\∈\in
        \\∉\notin
        \\⊆\subseteq
    , .{});
}

test "delimiters" {
    try expect("<math><mo stretchy=\"false\">(</mo><mi>A</mi><mo stretchy=\"false\">)</mo></math>", "(A)", .{});
    try expect("<math><mo>(</mo><mi>A</mi><mo>)</mo></math>", "\\left(A\\right)", .{});
}

test "sqrt" {
    try expect(
        "<math><msqrt><mn>2</mn></msqrt><mo>+</mo><msqrt><mi>x</mi><mi>y</mi></msqrt></math>",
        "\\sqrt2+\\sqrt{xy}",
        .{},
    );
}

test "spacing" {
    try expect("<math><mspace width=\"1em\"/></math>", "\\quad", .{});
    try expect("<math><mspace width=\"0.278em\"/></math>", "\\;", .{});
    try expect("<math><mspace width=\"0.1667em\"/></math>", "\\,", .{});
}

test "phantom" {
    try expect("<math><mphantom><mi>x</mi></mphantom></math>", "\\phantom x", .{});
}

test "fractions" {
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac12", .{});
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac{1}{2}", .{});
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac1{2}", .{});
    try expect("<math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>", "\\frac{1}2", .{});
}

test "subscripts" {
    try expect("<math><msub><mi>a</mi><mn>1</mn></msub></math>", "a_1", .{});
    try expect("<math><msub><mi>a</mi><mn>1</mn></msub><mn>2</mn></math>", "a_12", .{});
    try expect("<math><msub><mi>a</mi><mn>12</mn></msub></math>", "a_{12}", .{});
}

test "superscripts" {
    try expect("<math><msup><mi>a</mi><mn>1</mn></msup></math>", "a^1", .{});
    try expect("<math><msup><mi>a</mi><mn>1</mn></msup><mn>2</mn></math>", "a^12", .{});
    try expect("<math><msup><mi>a</mi><mn>12</mn></msup></math>", "a^{12}", .{});
}

test "R squared" {
    try expect("<math><msup><mi>ℝ</mi><mn>2</mn></msup></math>", "\\mathbb{R}^2", .{});
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
    , "(x+y)^2", .{});
}

test "vectors" {
    try expect("<math><mover><mi>x</mi><mo stretchy=\"false\" lspace=\"0\" rspace=\"0\">→</mo></mover></math>", "\\vec x", .{});
    try expect("<math><mover><mi>x</mi><mo stretchy=\"false\" lspace=\"0\" rspace=\"0\">→</mo></mover></math>", "\\vec{x}", .{});
    try expect("<math><mover><mrow><mi>P</mi><mi>Q</mi></mrow><mo stretchy=\"false\" lspace=\"0\" rspace=\"0\">→</mo></mover></math>", "\\vec{PQ}", .{});
}

test "boxed" {
    try expect("<math><mrow style=\"padding: 0.25em; border: 1px solid\"><mi>x</mi></mrow></math>", "\\boxed x", .{});
    try expect("<math><mrow style=\"padding: 0.25em; border: 1px solid\"><mi>x</mi></mrow></math>", "\\boxed{x}", .{});
}

test "set with braces" {
    try expect(
        "<math><mo stretchy=\"false\">{</mo><mn>1</mn><mo>,</mo><mn>2</mn><mo stretchy=\"false\">}</mo></math>",
        "\\{1,2\\}",
        .{},
    );
}

test "limit" {
    try expect(
        "<math><munder><mi>lim</mi><mrow><mi>x</mi><mo lspace=\"0\" rspace=\"0\">→</mo><mi>∞</mi></mrow></munder><mi>x</mi></math>",
        "\\lim_{x\\to\\infty}x",
        .{},
    );
}

test "summation" {
    try expect("<math><munderover><mo>∑</mo><mi>a</mi><mi>b</mi></munderover></math>", "\\sum_a^b", .{});
}

test "summation equation" {
    try expect(
        \\<math><munderover><mo>∑</mo>
        \\<mrow><mi>k</mi><mo lspace="0" rspace="0">=</mo><mn>1</mn></mrow><mi>n</mi></munderover>
        \\<mi>k</mi><mo>=</mo><mfrac><mrow><mi>k</mi>
        \\<mo stretchy="false">(</mo><mi>k</mi><mo>+</mo><mn>1</mn><mo stretchy="false">)</mo>
        \\</mrow><mn>2</mn></mfrac></math>
    ,
        "\\sum_ \n {k=1}^n \n k=\\frac{k \n (k+1) \n }2",
        .{},
    );
}

test "variant characters" {
    try expect("<math><mi mathvariant=\"normal\">a</mi></math>", "\\mathrm a", .{});
    try expect("<math><mi>𝐚</mi></math>", "\\mathbf a", .{});
    try expect("<math><mi>𝕒</mi></math>", "\\mathbb a", .{});
    try expect("<math><mi>𝒶</mi></math>", "\\mathcal a", .{});

    try expect("<math><mi mathvariant=\"normal\">z</mi></math>", "\\mathrm{z}", .{});
    try expect("<math><mi>𝐳</mi></math>", "\\mathbf{z}", .{});
    try expect("<math><mi>𝕫</mi></math>", "\\mathbb{z}", .{});
    try expect("<math><mi>𝓏</mi></math>", "\\mathcal{z}", .{});

    try expect("<math><mi mathvariant=\"normal\">A</mi></math>", "\\mathrm A", .{});
    try expect("<math><mi>𝐀</mi></math>", "\\mathbf A", .{});
    try expect("<math><mi>𝔸</mi></math>", "\\mathbb A", .{});
    try expect("<math><mi>𝒜</mi></math>", "\\mathcal A", .{});

    try expect("<math><mi mathvariant=\"normal\">Z</mi></math>", "\\mathrm{Z}", .{});
    try expect("<math><mi>𝐙</mi></math>", "\\mathbf{Z}", .{});
    try expect("<math><mi>ℤ</mi></math>", "\\mathbb{Z}", .{});
    try expect("<math><mi>𝒵</mi></math>", "\\mathcal{Z}", .{});
}

test "mrows" {
    try expect(
        "<math><mfrac><mrow><mi>a</mi><mi>b</mi></mrow><mrow><mi>c</mi><mi>d</mi></mrow></mfrac></math>",
        "\\frac{ab}{cd}",
        .{},
    );
}

test "quadratic formula" {
    try expect(
        \\<math display="block"><mi>x</mi><mo>=</mo><mo form="prefix">−</mo><mi>b</mi>
        ++
        \\<mo>±</mo><mfrac><msqrt><msup><mi>b</mi><mn>2</mn></msup><mo>−</mo>
        ++
        \\<mn>4</mn><mi>a</mi><mi>c</mi></msqrt><mrow><mn>2</mn><mi>a</mi></mrow></mfrac></math>
    ,
        \\x = -b \pm \frac{\sqrt{b^2 - 4 a c}}{2 a}
    , .{ .block = true });
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
    , .{ .block = true });
}

test "bmatrix environment" {
    try expect(
        "<math><mrow><mo>[</mo><mtable><mtr><mtd><mi>x</mi></mtd></mtr></mtable><mo>]</mo></mrow></math>",
        "\\begin{bmatrix}x\\end{bmatrix}",
        .{},
    );
}

test "cases environment" {
    try expect(
        \\<math><mi>f</mi><mo stretchy="false">(</mo><mi>x</mi><mo stretchy="false">)</mo><mo>=</mo>
        \\<mrow><mo>{</mo><mtable><mtr><mtd>
        \\<mn>1</mn></mtd><mtd><mtext>if</mtext><mspace width="0.278em"/><mi>x</mi><mo>></mo><mn>0</mn></mtd></mtr><mtr><mtd>
        \\<mn>0</mn></mtd><mtd><mtext>if</mtext><mspace width="0.278em"/><mi>x</mi><mo>=</mo><mn>0</mn></mtd></mtr><mtr><mtd>
        \\<mo form="prefix">−</mo><mn>1</mn></mtd><mtd><mtext>if</mtext><mspace width="0.278em"/><mi>x</mi><mo>&lt;</mo><mn>0</mn>
        \\</mtd></mtr></mtable></mrow></math>
    ,
        \\f(x)=
        \\\begin{cases}
        \\1 & \text{if}\; x > 0 \\
        \\0 & \text{if}\; x = 0 \\
        \\-1 & \text{if}\; x < 0
        \\\end{cases}
    , .{});
}

test "missing macro name" {
    try expectFailure("<input>:1:6: expected a macro name", "1 + \\", .{});
}

test "invalid macro name" {
    try expectFailure("<input>:1:2: \"foo\": unknown macro", "\\foo", .{});
}

test "invalid variant letter" {
    try expectFailure("<input>:1:9: \"0\": invalid letter", "\\mathbf{0}", .{});
}

test "invalid character" {
    try expectFailure("<input>:1:1: \"#\": unexpected character", "#", .{});
}

test "invalid close brace" {
    try expectFailure("<input>:1:1: unexpected '}'", "}", .{});
}

test "invalid empty braces" {
    try expectFailure("<input>:1:7: \"}\": unexpected character", "\\frac{}", .{});
}

test "unclosed mrow" {
    try expectFailure("<input>:1:2: unclosed <mrow> tag", "{", .{});
}

test "unclosed msqrt" {
    try expectFailure("<input>:1:6: unclosed <msqrt> tag", "\\sqrt", .{});
}

test "unclosed msub" {
    try expectFailure("<input>:1:3: unclosed <msub> tag", "1_", .{});
}

test "unclosed environment" {
    try expectFailure("<input>:1:15: unclosed matrix environment", "\\begin{matrix}", .{});
}

test "exceed max depth" {
    try expectFailure(
        \\<input>:1:30: exceeded maximum tag depth (8)
    ,
        \\\sqrt{\sqrt{\sqrt{\sqrt{\sqrt{x}}}}}
    , .{});
}

test "invalid environment name" {
    try expectFailure("<input>:1:8: \"foo\": unknown environment", "\\begin{foo}", .{});
}

test "mismatched environment name" {
    try expectFailure("<input>:1:27: expected \\end{bmatrix}", "\\begin{bmatrix}\\end{cases}", .{});
}

test "unexpected end environment" {
    try expectFailure("<input>:1:13: unexpected end environment", "\\end{matrix}", .{});
}

test "unexpected &" {
    try expectFailure("<input>:1:2: unexpected &", "&", .{});
}

test "unexpected \\\\" {
    try expectFailure("<input>:1:3: unexpected \\\\", "\\\\", .{});
}
