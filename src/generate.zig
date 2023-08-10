// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Date = @import("Date.zig");
const Markdown = @import("Markdown.zig");
const Status = @import("Metadata.zig").Status;
const Post = @import("Post.zig");
const Scanner = @import("Scanner.zig");
const Span = Scanner.Span;
const Reporter = @import("Reporter.zig");
const Template = @import("Template.zig");
const Scope = Template.Scope;
const Value = Template.Value;

pub fn generate(args: struct {
    arena: *ArenaAllocator,
    reporter: *Reporter,
    out_dir: []const u8,
    templates: std.StringHashMap(Template),
    posts: []const Post,
    base_url: ?[]const u8,
    home_url: ?[]const u8,
    font_url: ?[]const u8,
    analytics: ?[]const u8,
}) !void {
    const allocator = args.arena.allocator();
    const reporter = args.reporter;
    var dirs = try Directories.init(args.out_dir);
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
        .analytics = args.analytics, // TODO read file
    });
    var scope = Scope.init(variables);

    var per_file_arena = std.heap.ArenaAllocator.init(args.arena.child_allocator);
    defer per_file_arena.deinit();
    const per_file_allocator = per_file_arena.allocator();

    dirs.@"/".symLink(try fs.cwd().realpathAlloc(per_file_allocator, "assets/css/style.css"), "style.css", .{}) catch |err| switch (err) {
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
}

const Directories = struct {
    @"/": fs.Dir,
    @"/post": fs.Dir,
    @"/categories": fs.Dir,

    fn init(root_path: []const u8) !Directories {
        const root = try fs.cwd().makeOpenPath(root_path, .{});
        return Directories{
            .@"/" = root,
            .@"/post" = try root.makeOpenPath("post", .{}),
            .@"/categories" = try root.makeOpenPath("categories", .{}),
        };
    }

    fn close(self: *Directories) void {
        inline for (std.meta.fields(Directories)) |field| @field(self, field.name).close();
    }
};

const Templates = struct {
    @"index.html": Template,
    @"feed.xml": Template,
    @"listing.html": Template,
    @"post.html": Template,

    fn init(reporter: *Reporter, map: std.StringHashMap(Template)) !Templates {
        var result: Templates = undefined;
        inline for (std.meta.fields(Templates)) |field|
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
    dirs: Directories,
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
                    .posts = try recentPostSummaries(allocator, base_url, posts),
                    // TODO maybe just use {{ base_url }}/post/ in templates?
                    .archive_url = try base_url.join(allocator, "/post/"),
                    .categories_url = try base_url.join(allocator, "/categories/"),
                });
            },
            else => break :blk try Value.init(allocator, .{
                .title = "Mitchell Kember",
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
    var buffered = std.io.bufferedWriter(file.writer());
    try template.execute(allocator, reporter, buffered.writer(), &scope);
}

const Summary = struct {
    date: Value,
    title: Value,
    href: []const u8,
    excerpt: Value,
};

const num_recent = 10;

fn recentPostSummaries(allocator: Allocator, base_url: BaseUrl, posts: []const Post) ![num_recent]Summary {
    var summaries: [num_recent]Summary = undefined;
    for (0..num_recent) |i| {
        const post = posts[i];
        summaries[i] = Summary{
            .date = renderDate(post.meta.status, .long),
            .title = renderMarkdown(post.meta.title, post, .{ .is_inline = true }),
            .href = try base_url.post(allocator, post.slug),
            .excerpt = renderMarkdown(post.document.body, post, .{ .first_block_only = true }),
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
    dirs: Directories,
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
        .title = renderMarkdown(post.meta.title, post, .{ .is_inline = true }),
        .subtitle = renderMarkdown(post.meta.subtitle, post, .{ .is_inline = true }),
        .date = renderDate(post.meta.status, .long),
        .article = renderMarkdown(post.document.body, post, .{}),
        .newer = try if (neighbors.newer) |newer| base_url.post(allocator, newer.slug) else base_url.join(allocator, "/"),
        .older = try if (neighbors.older) |older| base_url.post(allocator, older.slug) else base_url.join(allocator, "/post/"),
    });
    var scope = parent.initChild(variables);
    var buffered = std.io.bufferedWriter(file.writer());
    try templates.@"post.html".execute(allocator, reporter, buffered.writer(), &scope);
}

fn renderDate(status: Status, style: Date.Style) Value {
    return switch (status) {
        .draft => Value{ .string = "DRAFT" },
        .published => |date| Value{ .date = .{ .date = date, .style = style } },
    };
}

fn renderMarkdown(span: Span, post: Post, options: Markdown.Options) Value {
    return Value{
        .markdown = .{
            // TODO helper method for this? same doc new span
            .document = Markdown{
                .filename = post.document.filename,
                .body = span,
                .links = post.document.links,
            },
            .options = options,
        },
    };
}
