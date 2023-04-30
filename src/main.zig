// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const Post = @import("Post.zig");
const Scanner = @import("Scanner.zig");
const Template = @import("template.zig").Template;

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
    errdefer |err| if (err == error.LoggedScanError) process.exit(1);

    var timer = try Timer.start();

    var posts = try readPosts(allocator);
    timer.log("read {} posts", .{posts.len});

    var templates = try compileTemplates(allocator);
    timer.log("compiled {} templates", .{templates.count()});

    try fs.cwd().deleteTree(args.destdir);
    timer.log("deleted {s}", .{args.destdir});

    const destdir = try fs.cwd().makeOpenPath(args.destdir, .{});
    _ = destdir;
}

const Timer = struct {
    timer: std.time.Timer,

    fn start() !Timer {
        return .{ .timer = try std.time.Timer.start() };
    }

    fn log(self: *Timer, comptime format: []const u8, args: anytype) void {
        const nanos = self.timer.lap();
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

fn readPosts(allocator: Allocator) ![]Post {
    var posts = std.ArrayList(Post).init(allocator);
    var iterable = try fs.cwd().openIterableDir(source_post_dir, .{});
    defer iterable.close();
    var iter = iterable.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;
        var file = try iterable.dir.openFile(entry.name, .{});
        defer file.close();
        try posts.append(try Post.parse(
            try fs.path.join(allocator, &[_][]const u8{ source_post_dir, entry.name }),
            try file.readToEndAlloc(allocator, max_file_size),
        ));
    }
    return posts.items;
}

fn compileTemplates(allocator: Allocator) !std.StringHashMap(Template) {
    var iterable = try fs.cwd().openIterableDir(template_dir, .{});
    defer iterable.close();
    var iter = iterable.iterate();
    while (try iter.next()) |entry| {
        if (entry.name[0] == '.') continue;
        const path = try fs.path.join(allocator, &[_][]const u8{ template_dir, entry.name });
        var file = try iterable.dir.openFile(entry.name, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, max_file_size);
        var scanner = Scanner{ .filename = path, .source = content };
        _ = scanner;
    }
    return std.StringHashMap(Template).init(allocator);
}
