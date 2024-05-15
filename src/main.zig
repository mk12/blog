// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const constants = @import("constants.zig");
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const generate = @import("generate.zig").generate;
const Allocator = mem.Allocator;
const Post = @import("Post.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Template = @import("Template.zig");
const Value = Template.Value;

fn printUsage(writer: anytype) !void {
    const program_name = fs.path.basename(mem.span(std.os.argv[0]));
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try parseArguments(allocator);
    var reporter = Reporter.init(allocator);
    errdefer |err| if (err == error.ErrorWasReported) {
        std.io.getStdErr().writer().print("{s}\n", .{reporter.message.?}) catch {};
        process.exit(1);
    };
    const templates = try readTemplates(allocator, &reporter);
    const posts = try readPosts(allocator, &reporter);
    try generate(&arena, &reporter, templates, posts, args.files);
}

const Arguments = struct {
    files: []const []const u8,
};

fn parseArguments(allocator: Allocator) !Arguments {
    var files = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, std.os.argv.len - 1);
    for (std.os.argv[1..]) |ptr| {
        const arg = mem.span(ptr);
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            try printUsage(std.io.getStdOut().writer());
            process.exit(0);
        } else if (mem.startsWith(u8, arg, "-")) {
            std.log.err("{s}: invalid flag", .{arg});
            process.exit(1);
        } else {
            files.appendAssumeCapacity(arg);
        }
    }
    return Arguments{ .files = files.items };
}

fn readTemplates(allocator: Allocator, reporter: *Reporter) !std.StringHashMapUnmanaged(Value) {
    var templates = std.StringHashMapUnmanaged(Value){};
    var dir = try fs.cwd().openDir(constants.src_template_dir, .{});
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;
        const name = try allocator.dupe(u8, entry.name);
        var scanner = Scanner{
            .source = try dir.readFileAlloc(allocator, name, constants.max_file_size),
            .filename = try fs.path.join(allocator, &.{ constants.src_template_dir, name }),
            .reporter = reporter,
        };
        try templates.put(allocator, name, Value{ .template = try Template.parse(allocator, &scanner) });
    }
    return templates;
}

fn readPosts(allocator: Allocator, reporter: *Reporter) ![]const Post {
    var posts = std.ArrayList(Post).init(allocator);
    var dir = try fs.cwd().openDir(constants.src_post_dir, .{});
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.eql(u8, fs.path.extension(entry.name), ".md")) continue;
        var scanner = Scanner{
            .source = try dir.readFileAlloc(allocator, entry.name, constants.max_file_size),
            .filename = try fs.path.join(allocator, &.{ constants.src_post_dir, entry.name }),
            .reporter = reporter,
        };
        try posts.append(try Post.parse(allocator, &scanner));
    }
    mem.sort(Post, posts.items, {}, cmpPostsReverseChronological);
    return posts.items;
}

fn cmpPostsReverseChronological(_: void, lhs: Post, rhs: Post) bool {
    return Post.order(lhs, rhs) == .gt;
}

test {
    _ = std.testing.refAllDecls(@This());
}
