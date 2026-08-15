// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const constants = @import("constants.zig");
const std = @import("std");
const mem = std.mem;
const process = std.process;
const generate = @import("generate.zig").generate;
const Allocator = mem.Allocator;
const Document = @import("Document.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Template = @import("Template.zig");
const Value = Template.Value;

fn printUsage(writer: *std.Io.Writer, argv0: []const u8) !void {
    const program_name = std.fs.path.basename(argv0);
    try writer.print(
        \\Usage: {s} [FILE ...]
        \\
        \\Site generator
        \\
        \\Arguments:
        \\    FILE  Only compile these source files
        \\
    , .{program_name});
}

pub fn main(init: std.process.Init) !void {
    var arena = init.arena;
    const io = init.io;
    const allocator = arena.allocator();
    const args = try parseArguments(allocator, io, init.minimal.args);
    var reporter = Reporter.init(allocator);
    mainImpl(io, arena, &reporter, args) catch |err| switch (err) {
        error.ErrorWasReported => {
            var buffer: [1024]u8 = undefined;
            var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
            const stderr = &stderr_writer.interface;
            stderr.print("{s}\n", .{reporter.message.?}) catch {};
            try stderr.flush();
            process.exit(1);
        },
        else => return err,
    };
}

fn mainImpl(io: std.Io, arena: *std.heap.ArenaAllocator, reporter: *Reporter, args: Arguments) !void {
    const allocator = arena.allocator();
    const templates = try readTemplates(allocator, io, reporter);
    const posts = try readDocuments(allocator, io, reporter, "/blog", cmpByDate, .{ .default_template = "post.html", .date_required = true });
    const crafts = try readDocuments(allocator, io, reporter, "/crafts", cmpByDate, .{ .default_template = "craft.html", .date_required = true });
    const books = try readDocuments(allocator, io, reporter, "/books", cmpByDate, .{ .default_template = "book.html", .date_required = true });
    const recipes = try readDocuments(allocator, io, reporter, "/recipes", cmpBySlug, .{ .default_template = "recipe.html", .date_required = true });
    try generate(io, arena, reporter, templates, posts, crafts, books, recipes, args.files);
}

const Arguments = struct {
    files: []const []const u8,
};

fn parseArguments(allocator: Allocator, io: std.Io, args: std.process.Args) !Arguments {
    var files: std.ArrayList([]const u8) = .empty;
    var it = args.iterate();
    const argv0 = it.next() orelse return error.InvalidArgv;
    while (it.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            var buffer: [1024]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
            const stdout = &stdout_writer.interface;
            try printUsage(stdout, argv0);
            try stdout.flush();
            process.exit(0);
        } else if (mem.startsWith(u8, arg, "-")) {
            std.log.err("{s}: invalid flag", .{arg});
            process.exit(1);
        } else {
            try files.append(allocator, arg);
        }
    }
    return Arguments{ .files = files.items };
}

fn readTemplates(allocator: Allocator, io: std.Io, reporter: *Reporter) !std.StringHashMapUnmanaged(Value) {
    var templates: std.StringHashMapUnmanaged(Value) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, constants.src_template_dir, .{});
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        const name = try allocator.dupe(u8, entry.name);
        var scanner = Scanner{
            .source = try dir.readFileAlloc(io, name, allocator, constants.max_file_size),
            .filename = try std.fs.path.join(allocator, &.{ constants.src_template_dir, name }),
            .reporter = reporter,
        };
        try templates.put(allocator, name, Value{ .template = try Template.parse(allocator, &scanner) });
    }
    return templates;
}

fn readDocuments(
    allocator: Allocator,
    io: std.Io,
    reporter: *Reporter,
    comptime path: []const u8,
    order: fn (void, lhs: Document, rhs: Document) bool,
    options: Document.Options,
) ![]const Document {
    var documents = std.ArrayList(Document).empty;
    const dir_name = constants.src_site_dir ++ path;
    var dir = try std.Io.Dir.cwd().openDir(io, dir_name, .{});
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        var scanner = switch (entry.kind) {
            .directory => blk: {
                var subdir = try dir.openDir(io, entry.name, .{});
                defer subdir.close(io);
                const index = "index.md";
                break :blk Scanner{
                    .source = subdir.readFileAlloc(io, index, allocator, constants.max_file_size) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    },
                    .filename = try std.fs.path.join(allocator, &.{ dir_name, entry.name, index }),
                    .reporter = reporter,
                };
            },
            .file => blk: {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".md")) continue;
                if (std.mem.eql(u8, entry.name, "index.md")) continue;
                break :blk Scanner{
                    .source = try dir.readFileAlloc(io, entry.name, allocator, constants.max_file_size),
                    .filename = try std.fs.path.join(allocator, &.{ dir_name, entry.name }),
                    .reporter = reporter,
                };
            },
            else => continue,
        };
        try documents.append(allocator, try Document.parse(allocator, &scanner, options));
    }
    mem.sort(Document, documents.items, {}, order);
    return documents.items;
}

fn cmpBySlug(_: void, lhs: Document, rhs: Document) bool {
    return mem.order(u8, lhs.slug, rhs.slug) == .lt;
}

fn cmpByDate(_: void, lhs: Document, rhs: Document) bool {
    return lhs.date.?.sortKey() > rhs.date.?.sortKey();
}

test {
    _ = std.testing.refAllDecls(@This());
}
