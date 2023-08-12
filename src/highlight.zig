// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fmt = std.fmt;
const Scanner = @import("Scanner.zig");

pub fn highlight(writer: anytype, scanner: *Scanner, language: ?[]const u8) !void {
    _ = language;
    const start = scanner.offset;
    while (true) {
        _ = try scanner.until('\n');
        if (scanner.attempt("```")) break;
    }
    try writer.writeAll(scanner.source[start .. scanner.offset - 4]);
}
