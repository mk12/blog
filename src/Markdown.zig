// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const Scanner = @import("Scanner.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Markdown = @This();

source: []const u8,
filename: []const u8,
location: Location,

pub fn render(self: Markdown, reporter: *Reporter, writer: anytype) !void {
    _ = reporter;
    try writer.writeAll("<!-- MARKDOWN -->");
    try writer.writeAll(self.source);
}
