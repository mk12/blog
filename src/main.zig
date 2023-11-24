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

fn printUsage(writer: anytype) !void {
    const program_name = fs.path.basename(mem.span(std.os.argv[0]));
    try writer.print(
        \\Usage: {s} [-hdc] OUT_DIR
        \\
        \\Generate static files for the blog
        \\
        \\Arguments:
        \\    OUT_DIR      Output directory
        \\
        \\Options:
        \\    -h, --help   Show this help message
        \\    -d, --draft  Include draft posts
        \\    -c, --clean  Remove OUT_DIR first
        \\
        \\Environment:
        \\    BASE_URL     Base URL where the blog is hosted
        \\    HOME_URL     URL to link to when embedding in a larger site
        \\    FONT_URL     WOFF2 font directory URL
        \\    ANALYTICS    HTML file to include for analytics
        \\
    , .{program_name});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try parseArguments();
    const env = parseEnvironment();
    var reporter = Reporter.init(allocator);
    errdefer |err| if (err == error.ErrorWasReported) {
        std.log.err("{s}", .{reporter.message.?});
        process.exit(1);
    };
    const posts = try readPosts(allocator, &reporter, args.draft);
    const templates = try readTemplates(allocator, &reporter);
    if (args.clean) try fs.cwd().deleteTree(args.out_dir);
    try generate(.{
        .arena = &arena,
        .reporter = &reporter,
        .out_dir = args.out_dir,
        .templates = templates,
        .posts = posts,
        .base_url = env.base_url,
        .home_url = env.home_url,
        .font_url = env.font_url,
        .analytics = env.analytics,
    });
}

const Arguments = struct {
    out_dir: []const u8,
    draft: bool = false,
    clean: bool = false,
};

fn parseArguments() !Arguments {
    var args = Arguments{ .out_dir = undefined };
    var out_dir: ?[]const u8 = null;
    for (std.os.argv[1..]) |ptr| {
        const arg = mem.span(ptr);
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            try printUsage(std.io.getStdOut().writer());
            process.exit(0);
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--draft")) {
            args.draft = true;
        } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--clean")) {
            args.clean = true;
        } else if (mem.startsWith(u8, arg, "-")) {
            std.log.err("{s}: invalid argument", .{arg});
            process.exit(1);
        } else if (out_dir != null) {
            try printUsage(std.io.getStdErr().writer());
            process.exit(1);
        } else {
            out_dir = arg;
        }
    }
    args.out_dir = out_dir orelse {
        try printUsage(std.io.getStdErr().writer());
        process.exit(1);
    };
    return args;
}

const Environment = struct {
    base_url: ?[]const u8,
    home_url: ?[]const u8,
    font_url: ?[]const u8,
    analytics: ?[]const u8,
};

fn parseEnvironment() Environment {
    return Environment{
        .base_url = std.os.getenv("BASE_URL"),
        .home_url = std.os.getenv("HOME_URL"),
        .font_url = std.os.getenv("FONT_URL"),
        .analytics = std.os.getenv("ANALYTICS"),
    };
}

fn readPosts(allocator: Allocator, reporter: *Reporter, include_drafts: bool) ![]const Post {
    var posts = std.ArrayList(Post).init(allocator);
    var iterable = try fs.cwd().openIterableDir(constants.post_dir, .{});
    defer iterable.close();
    var iter = iterable.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;
        var scanner = Scanner{
            .source = try iterable.dir.readFileAlloc(allocator, entry.name, constants.max_file_size),
            .filename = try fs.path.join(allocator, &.{ constants.post_dir, entry.name }),
            .reporter = reporter,
        };
        const post = try Post.parse(allocator, &scanner);
        if (!include_drafts and post.meta.status == .draft) continue;
        try posts.append(post);
    }
    mem.sort(Post, posts.items, {}, cmpPostsReverseChronological);
    return posts.items;
}

fn cmpPostsReverseChronological(_: void, lhs: Post, rhs: Post) bool {
    return Post.order(lhs, rhs) == .gt;
}

fn readTemplates(allocator: Allocator, reporter: *Reporter) !std.StringHashMap(Template) {
    var templates = std.StringHashMap(Template).init(allocator);
    var iterable = try fs.cwd().openIterableDir(constants.template_dir, .{});
    defer iterable.close();
    {
        var iter = iterable.iterate();
        while (try iter.next()) |entry| {
            if (entry.name[0] == '.') continue;
            const key = try allocator.dupe(u8, entry.name);
            try templates.put(key, undefined);
        }
    }
    var iter = templates.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        var scanner = Scanner{
            .source = try iterable.dir.readFileAlloc(allocator, name, constants.max_file_size),
            .filename = try fs.path.join(allocator, &.{ constants.template_dir, name }),
            .reporter = reporter,
        };
        entry.value_ptr.* = try Template.parse(allocator, &scanner, templates);
    }
    return templates;
}

test {
    _ = std.testing.refAllDecls(@This());
}
