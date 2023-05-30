// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const Post = @import("Post.zig");
const Reporter = @import("Reporter.zig");
const Scanner = @import("Scanner.zig");
const Template = @import("Template.zig");

pub const std_options = struct {
    pub const log_level = .info;
};

fn printUsage(writer: anytype) !void {
    const program_name = fs.path.basename(mem.span(std.os.argv[0]));
    try writer.print(
        \\Usage: {s} [-hd] DESTDIR
        \\
        \\Generate static files for the blog
        \\
        \\Arguments:
        \\    DESTDIR      Destination directory
        \\
        \\Options:
        \\    -h, --help   Show this help message
        \\    -d, --draft  Include draft posts
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
    _ = env;
    errdefer |err| if (err == error.ErrorWasReported) process.exit(1);

    var timer = try Timer.start();

    var posts = try readPosts(allocator);
    timer.log("read {} posts", .{posts.items.len});

    var templates = try readTemplates(allocator);
    timer.log("read {} templates", .{templates.count()});

    try fs.cwd().deleteTree(args.destdir);
    timer.log("deleted {s}", .{args.destdir});

    const destdir = try fs.cwd().makeOpenPath(args.destdir, .{});
    _ = destdir;
}

const Timer = struct {
    inner: std.time.Timer,

    fn start() !Timer {
        return .{ .inner = try std.time.Timer.start() };
    }

    fn log(timer: *Timer, comptime format: []const u8, args: anytype) void {
        const nanos = timer.inner.lap();
        std.log.info(format ++ " in {} µs", args ++ .{nanos / 1000});
    }
};

const Arguments = struct {
    destdir: []const u8,
    draft: bool = false,
};

fn parseArguments() !Arguments {
    var args = Arguments{ .destdir = undefined };
    var destdir: ?[]const u8 = null;
    for (std.os.argv[1..]) |ptr| {
        const arg = mem.span(ptr);
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            try printUsage(std.io.getStdOut().writer());
            process.exit(0);
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--draft")) {
            args.draft = true;
        } else if (mem.startsWith(u8, arg, "-")) {
            std.log.err("{s}: invalid argument", .{arg});
            process.exit(1);
        } else if (destdir != null) {
            try printUsage(std.io.getStdErr().writer());
            process.exit(1);
        } else {
            destdir = arg;
        }
    }
    args.destdir = destdir orelse {
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

const source_post_dir = "posts";
const template_dir = "templates";
const max_file_size = 1024 * 1024;

fn readPosts(allocator: Allocator) !std.ArrayList(Post) {
    var posts = std.ArrayList(Post).init(allocator);
    var iterable = try fs.cwd().openIterableDir(source_post_dir, .{});
    defer iterable.close();
    var iter = iterable.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;
        var file = try iterable.dir.openFile(entry.name, .{});
        defer file.close();
        const source = try file.readToEndAlloc(allocator, max_file_size);
        const reporter = Reporter{
            .filename = try fs.path.join(allocator, &.{ source_post_dir, entry.name }),
        };
        var scanner = Scanner{ .source = source, .reporter = reporter };
        try posts.append(try Post.parse(&scanner));
    }
    return posts;
}

fn readTemplates(allocator: Allocator) !std.StringHashMap(Template) {
    var templates = std.StringHashMap(Template).init(allocator);
    var iterable = try fs.cwd().openIterableDir(template_dir, .{});
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
        var file = try iterable.dir.openFile(name, .{});
        defer file.close();
        const source = try file.readToEndAlloc(allocator, max_file_size);
        const reporter = Reporter{
            .filename = try fs.path.join(allocator, &.{ source_post_dir, name }),
        };
        var scanner = Scanner{ .source = source, .reporter = reporter };
        entry.value_ptr.* = try Template.parse(allocator, &scanner, templates);
    }
    return templates;
}

test {
    _ = std.testing.refAllDecls(@This());
}
