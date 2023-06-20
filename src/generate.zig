// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Markdown = @import("Markdown.zig");
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
    const reporter = args.reporter;
    const dirs = try Dirs.init(args.out_dir);
    defer dirs.close();
    const templates = try Templates.init(reporter, args.templates);
    const pages = std.enums.values(Page);
    const posts = args.posts;

    var variables = try Value.init(args.arena.allocator(), .{
        .author = "Mitchell Kember",
        .style_url = "style.css", // link.to
        .blog_url = "index.html", // link to
        .home_url = args.home_url,
        .analytics = args.analytics,
    });
    var scope = Scope.init(variables);

    var per_file_arena = std.heap.ArenaAllocator.init(args.arena.child_allocator);
    defer per_file_arena.deinit();
    const allocator = per_file_arena.allocator();
    for (pages) |page| {
        _ = per_file_arena.reset(.retain_capacity);
        try generatePage(allocator, reporter, dirs, templates, &scope, posts, page);
    }
    for (posts) |post| {
        _ = per_file_arena.reset(.retain_capacity);
        try generatePost(allocator, reporter, dirs, templates, &scope, post);
    }

    return pages.len + posts.len;
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

fn url(allocator: Allocator, base_url: ?[]const u8, source: []const u8, dest: []const u8) []const u8 {
    if (base_url) |base| {
        _ = base;
        return "";
    }
    return fs.path.relative(allocator, fs.path.dirname(source), dest);
}

fn generatePage(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Dirs,
    templates: Templates,
    parent: *const Scope,
    posts: []const Post,
    page: Page,
) !void {
    _ = posts;
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
                    .math = false,
                    .posts = .{},
                    .archive_url = "", // link.to
                    .categories_url = "", // link.to
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

fn generatePost(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Dirs,
    templates: Templates,
    parent: *const Scope,
    post: Post,
    // TODO neighbors
) !void {
    var dir = try dirs.@"/post".makeOpenPath(post.slug, .{});
    defer dir.close();
    var file = try dir.createFile("index.html", .{});
    defer file.close();
    const variables = try Value.init(allocator, .{
        .title = post.metadata.title,
        .description = post.metadata.description,
        .date = switch (post.metadata.status) {
            .draft => "DRAFT",
            .published => |date| try std.fmt.allocPrint(allocator, "{long}", .{date.fmt()}),
        },
        .article = Markdown{
            .source = post.source[post.markdown_offset..],
            .filename = post.filename,
            .location = post.markdown_location,
        },
        // TODO render and detect math
        .math = false,
        .older = "#",
        .newer = "#",
        // TODO style_url is fixed only if absolute URLs
        .style_url = "../../style.css",
    });
    var scope = parent.initChild(variables);
    try templates.@"post.html".execute(allocator, reporter, file.writer(), &scope);
}
