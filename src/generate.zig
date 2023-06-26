// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Markdown = @import("Markdown.zig");
const Status = @import("Metadata.zig").Status;
const Post = @import("Post.zig");
const Scanner = @import("Scanner.zig");
const Reporter = @import("Reporter.zig");
const Template = @import("Template.zig");
const Scope = Template.Scope;
const Value = Template.Value;

pub fn generate(args: struct {
    arena: *ArenaAllocator,
    reporter: *Reporter,
    out_dir: fs.Dir,
    templates: std.StringHashMap(Template),
    posts: []const Post,
    base_url: ?[]const u8,
    home_url: ?[]const u8,
    font_url: ?[]const u8,
    analytics: ?[]const u8,
}) !usize {
    const allocator = args.arena.allocator();
    const reporter = args.reporter;
    const dirs = try Dirs.init(args.out_dir);
    defer dirs.close();
    const base_url = BaseUrl.init(args.base_url);
    const templates = try Templates.init(reporter, args.templates);
    const pages = std.enums.values(Page);
    const posts = args.posts;

    var variables = try Value.init(allocator, .{
        .author = "Mitchell Kember",
        .style_url = try base_url.join(allocator, "/style.css"),
        .blog_url = try base_url.join(allocator, "/"),
        .home_url = args.home_url,
        .analytics = args.analytics,
    });
    var scope = Scope.init(variables);

    var per_file_arena = std.heap.ArenaAllocator.init(args.arena.child_allocator);
    defer per_file_arena.deinit();
    const per_file_allocator = per_file_arena.allocator();

    dirs.@"/".symLink(try fs.cwd().realpathAlloc(allocator, "assets/css/style.css"), "style.css", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    for (pages) |page| {
        _ = per_file_arena.reset(.retain_capacity);
        try generatePage(per_file_allocator, reporter, dirs, base_url, templates, &scope, posts, page);
    }
    for (posts, 0..) |post, i| {
        _ = per_file_arena.reset(.retain_capacity);
        const neighbors = Neighbors{
            .newer = if (i > 0) &posts[i - 1] else null,
            .older = if (i < posts.len - 1) &posts[i + 1] else null,
        };
        try generatePost(per_file_allocator, reporter, dirs, base_url, templates, &scope, post, neighbors);
    }

    return 1 + pages.len + posts.len;
}

const Dirs = struct {
    @"/": fs.Dir,
    @"/post": fs.Dir,
    @"/categories": fs.Dir,

    fn init(root: fs.Dir) !Dirs {
        var result: Dirs = undefined;
        result.@"/" = root;
        inline for (@typeInfo(Dirs).Struct.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "/")) continue;
            @field(result, field.name) = try root.makeOpenPath(field.name[1..], .{});
        }
        return result;
    }

    fn close(self: Dirs) void {
        inline for (@typeInfo(Dirs).Struct.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "/")) continue;
            var dir = @field(self, field.name);
            dir.close();
        }
    }
};

const Templates = struct {
    @"index.html": Template,
    @"feed.xml": Template,
    @"listing.html": Template,
    @"post.html": Template,

    fn init(reporter: *Reporter, map: std.StringHashMap(Template)) !Templates {
        var result: Templates = undefined;
        inline for (@typeInfo(Templates).Struct.fields) |field|
            @field(result, field.name) = map.get(field.name) orelse
                return reporter.fail("{s}: template not found", .{field.name});
        return result;
    }
};

const Page = enum {
    @"/index.html",
    @"/index.xml",
    @"/post/index.html",
    @"/categories/index.html",
};

const BaseUrl = struct {
    base: []const u8,

    fn init(base: ?[]const u8) BaseUrl {
        return BaseUrl{ .base = base orelse "" };
    }

    fn join(self: BaseUrl, allocator: Allocator, comptime path: []const u8) ![]const u8 {
        if (path[0] != '/') @compileError(path ++ ": does not start with slash");
        return std.mem.concat(allocator, u8, &.{ self.base, path });
    }

    fn fmt(self: BaseUrl, allocator: Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
        if (format[0] != '/') @compileError(format ++ ": does not start with slash");
        return std.fmt.allocPrint(allocator, "{s}" ++ format, .{self.base} ++ args);
    }

    fn post(self: BaseUrl, allocator: Allocator, slug: []const u8) ![]const u8 {
        return self.fmt(allocator, "/post/{s}/", .{slug});
    }
};

fn generatePage(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Dirs,
    base_url: BaseUrl,
    templates: Templates,
    parent: *const Scope,
    posts: []const Post,
    page: Page,
) !void {
    const file = switch (page) {
        inline else => |p| try @field(dirs, fs.path.dirname(@tagName(p)).?)
            .createFile(comptime fs.path.basename(@tagName(p)), .{}),
    };
    defer file.close();
    const template = switch (page) {
        .@"/index.html" => templates.@"index.html",
        .@"/index.xml" => templates.@"feed.xml",
        .@"/post/index.html", .@"/categories/index.html" => templates.@"listing.html",
    };
    const variables = blk: {
        switch (page) {
            .@"/index.html" => {
                break :blk try Value.init(allocator, .{
                    .title = "Mitchell Kember",
                    // TODO detect math
                    .math = false,
                    .posts = try recentPostSummaries(allocator, base_url, posts),
                    .archive_url = try base_url.join(allocator, "/post/"),
                    .categories_url = try base_url.join(allocator, "/categories/"),
                });
            },
            else => break :blk try Value.init(allocator, .{
                .title = "Mitchell Kember",
                .math = false,
                .posts = .{},
                .archive_url = "", // link.to
                .categories_url = "", // link.to
                .last_build_date = "",
                .feed_url = "",
                .groups = .{},
            }),
        }
    };
    var scope = parent.initChild(variables);
    try template.execute(allocator, reporter, file.writer(), &scope);
}

const Summary = struct {
    date: []const u8,
    title: []const u8,
    href: []const u8,
    excerpt: Markdown,
};

const num_recent = 10;

fn recentPostSummaries(allocator: Allocator, base_url: BaseUrl, posts: []const Post) ![num_recent]Summary {
    var summaries: [num_recent]Summary = undefined;
    for (0..num_recent) |i| {
        const post = posts[i];
        summaries[i] = Summary{
            .date = try renderDate(allocator, "{long}", post.meta.status),
            .title = post.meta.title,
            .href = try base_url.post(allocator, post.slug),
            .excerpt = post.body.summary(),
        };
    }
    return summaries;
}

const Neighbors = struct {
    newer: ?*const Post,
    older: ?*const Post,
};

fn generatePost(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Dirs,
    base_url: BaseUrl,
    templates: Templates,
    parent: *const Scope,
    post: Post,
    neighbors: Neighbors,
) !void {
    var dir = try dirs.@"/post".makeOpenPath(post.slug, .{});
    defer dir.close();
    var file = try dir.createFile("index.html", .{});
    defer file.close();
    const variables = try Value.init(allocator, .{
        .title = post.meta.title,
        .subtitle = post.meta.subtitle,
        .date = try renderDate(allocator, "{long}", post.meta.status),
        .article = post.body,
        // TODO render and detect math
        .math = false,
        .newer = try if (neighbors.newer) |newer| base_url.post(allocator, newer.slug) else base_url.join(allocator, "/"),
        .older = try if (neighbors.older) |older| base_url.post(allocator, older.slug) else base_url.join(allocator, "/post/"),
    });
    var scope = parent.initChild(variables);
    try templates.@"post.html".execute(allocator, reporter, file.writer(), &scope);
}

fn renderDate(allocator: Allocator, comptime format: []const u8, status: Status) ![]const u8 {
    return switch (status) {
        .draft => "DRAFT",
        .published => |date| try std.fmt.allocPrint(allocator, format, .{date.fmt()}),
    };
}
