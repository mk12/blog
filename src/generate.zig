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
    var hooks = Hooks{ .allocator = allocator, .base_url = base_url, .dirs = &dirs };
    const pages = std.enums.values(Page);
    const posts = args.posts;

    var variables = try Value.init(allocator, .{
        .author = "Mitchell Kember",
        .style_url = try base_url.join(allocator, "/style.css"),
        .blog_url = try base_url.join(allocator, "/"),
        .home_url = args.home_url,
        // TODO maybe just use {{ base_url }}/post/ in templates?
        .archive_url = try base_url.join(allocator, "/post/"),
        .categories_url = try base_url.join(allocator, "/categories/"),
        .analytics = if (args.analytics) |path| try fs.cwd().readFileAlloc(allocator, path, 1024) else null,
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
        try generatePage(per_file_allocator, reporter, dirs, base_url, templates, &hooks, &scope, posts, page);
    }

    for (posts, 0..) |post, i| {
        _ = per_file_arena.reset(.retain_capacity);
        const neighbors = Neighbors{
            .newer = if (i > 0) &posts[i - 1] else null,
            .older = if (i < posts.len - 1) &posts[i + 1] else null,
        };
        try generatePost(per_file_allocator, reporter, dirs, base_url, templates, &hooks, &scope, post, neighbors);
    }
}

const Directories = struct {
    @"/": fs.Dir,
    @"/post": fs.Dir,
    @"/categories": fs.Dir,
    @"/img": fs.Dir,

    fn init(root_path: []const u8) !Directories {
        const root = try fs.cwd().makeOpenPath(root_path, .{});
        return Directories{
            .@"/" = root,
            .@"/post" = try root.makeOpenPath("post", .{}),
            .@"/categories" = try root.makeOpenPath("categories", .{}),
            .@"/img" = try root.makeOpenPath("img", .{}),
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

    fn postUrl(self: BaseUrl, allocator: Allocator, slug: []const u8) ![]const u8 {
        return self.fmt(allocator, "/post/{s}/", .{slug});
    }
};

const Hooks = struct {
    allocator: Allocator,
    base_url: BaseUrl,
    embedded_assets: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    linked_assets: std.StringHashMapUnmanaged(void) = .{},
    dirs: *const Directories,

    pub fn writeUrl(self: *Hooks, writer: anytype, handle: Markdown.Handle, url: []const u8) !void {
        if (std.mem.startsWith(u8, url, "http")) return writer.writeAll(url);
        // Note: If in same page #foo, should render correctly when it's excerpt on main page too.
        const hash_idx = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
        if (hash_idx == 0) return handle.fail("direct #id links in same page not implemented yet", .{});
        const path = url[0..hash_idx];
        const fragment = url[hash_idx..];
        const source_dir = fs.path.dirname(handle.filename()).?;
        const dest = try fs.path.resolve(self.allocator, &.{ source_dir, path });
        // TODO don't duplicate "posts/" in main.zig and here
        if (std.mem.startsWith(u8, dest, "posts/")) {
            const filename = dest["posts/".len..];
            if (!std.mem.endsWith(u8, filename, ".md")) return handle.fail("{s}: expected .md extension", .{url});
            const slug = Post.parseSlug(filename);
            // TODO use base_url, make it support writer and allocator
            try std.fmt.format(writer, "{s}/post/{s}/{s}", .{ self.base_url.base, slug, fragment });
        } else {
            return handle.fail("{s}: cannot resolve internal url", .{url});
        }
    }

    pub fn writeImage(self: *Hooks, writer: anytype, handle: Markdown.Handle, url: []const u8) !void {
        // TODO: eliminate duplication with writeUrl
        const source_dir = fs.path.dirname(handle.filename()).?;
        const dest = try fs.path.resolve(self.allocator, &.{ source_dir, url });
        if (std.mem.startsWith(u8, dest, "assets/svg/")) {
            // TODO: make SVGs use CSS variables for dark/light mode
            const filename = dest["assets/svg/".len..];
            const result = try self.embedded_assets.getOrPut(self.allocator, filename);
            if (!result.found_existing) {
                const data = try fs.cwd().readFileAlloc(self.allocator, dest, 1024 * 1024);
                result.value_ptr.* = std.mem.trimRight(u8, data, "\n");
            }
            try writer.writeAll(result.value_ptr.*);
        } else if (std.mem.startsWith(u8, dest, "assets/img/")) {
            const filename = dest["assets/img/".len..];
            const result = try self.linked_assets.getOrPut(self.allocator, filename);
            if (!result.found_existing) {
                self.dirs.@"/img".symLink(try fs.cwd().realpathAlloc(self.allocator, dest), filename, .{}) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
            try std.fmt.format(writer, "<img src=\"/img/{s}\">", .{filename});
        } else {
            return handle.fail("{s}: cannot resolve internal url", .{url});
        }
    }
};

fn generatePage(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Directories,
    base_url: BaseUrl,
    templates: Templates,
    hooks: *Hooks,
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
    const variables = switch (page) {
        .@"/index.html" => try Value.init(allocator, .{
            .title = "Mitchell Kember",
            .posts = try recentPostSummaries(allocator, base_url, posts),
        }),
        .@"/post/index.html" => try Value.init(allocator, .{
            .title = "Post Archive",
            .groups = try groupPostsByYear(allocator, base_url, posts),
        }),
        else => try Value.init(allocator, .{
            .title = "Mitchell Kember",
            .posts = .{},
            .archive_url = "", // link.to
            .categories_url = "", // link.to
            .last_build_date = "",
            .feed_url = "",
            .groups = .{},
        }),
    };
    var scope = parent.initChild(variables);
    var buffer = std.io.bufferedWriter(file.writer());
    try template.execute(allocator, reporter, buffer.writer(), hooks, &scope);
    try buffer.flush();
}

const num_recent = 10;
const Summary = struct { date: Value, title: Value, href: []const u8, excerpt: Value };

fn recentPostSummaries(allocator: Allocator, base_url: BaseUrl, posts: []const Post) ![num_recent]Summary {
    var summaries: [num_recent]Summary = undefined;
    for (0..num_recent) |i| {
        const post = posts[i];
        summaries[i] = Summary{
            .date = date(post.meta.status, .long),
            .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
            .href = try base_url.postUrl(allocator, post.slug),
            .excerpt = markdown(post.body, post.context, .{ .first_block_only = true }),
        };
    }
    return summaries;
}

const Group = struct { name: []const u8, posts: []Entry };
const Entry = struct { date: Value, title: Value, href: []const u8 };

const unset_year: u16 = 0;
const draft_year: u16 = 1;

fn groupPostsByYear(allocator: Allocator, base_url: BaseUrl, posts: []const Post) ![]Group {
    var groups = std.ArrayList(Group).init(allocator);
    var year: u16 = unset_year;
    var entries = std.ArrayList(Entry).init(allocator);
    for (posts) |post| {
        const post_year = switch (post.meta.status) {
            .draft => draft_year,
            .published => |d| d.year,
        };
        try flushGroup(allocator, &groups, year, &entries, post_year);
        year = post_year;
        try entries.append(Entry{
            .date = date(post.meta.status, .short),
            .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
            .href = try base_url.postUrl(allocator, post.slug),
        });
    }
    try flushGroup(allocator, &groups, year, &entries, unset_year);
    return groups.items;
}

fn flushGroup(allocator: Allocator, groups: *std.ArrayList(Group), year: u16, entries: *std.ArrayList(Entry), post_year: u16) !void {
    if (year == post_year or entries.items.len == 0) return;
    const name = switch (year) {
        unset_year => unreachable,
        draft_year => "Drafts",
        else => |y| try std.fmt.allocPrint(allocator, "{}", .{y}),
    };
    try groups.append(Group{ .name = name, .posts = try entries.toOwnedSlice() });
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
    hooks: *Hooks,
    parent: *const Scope,
    post: Post,
    neighbors: Neighbors,
) !void {
    var dir = try dirs.@"/post".makeOpenPath(post.slug, .{});
    defer dir.close();
    var file = try dir.createFile("index.html", .{});
    defer file.close();
    const variables = try Value.init(allocator, .{
        .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
        .subtitle = markdown(post.meta.subtitle, post.context, .{ .is_inline = true }),
        .date = date(post.meta.status, .long),
        .content = markdown(post.body, post.context, .{ .shift_heading_level = 1 }),
        .newer = try if (neighbors.newer) |newer| base_url.postUrl(allocator, newer.slug) else base_url.join(allocator, "/"),
        .older = try if (neighbors.older) |older| base_url.postUrl(allocator, older.slug) else base_url.join(allocator, "/post/"),
    });
    var scope = parent.initChild(variables);
    var buffer = std.io.bufferedWriter(file.writer());
    try templates.@"post.html".execute(allocator, reporter, buffer.writer(), hooks, &scope);
    try buffer.flush();
}

fn date(status: Status, style: Date.Style) Value {
    return switch (status) {
        .draft => Value{ .string = "DRAFT" },
        .published => |d| Value{ .date = .{ .date = d, .style = style } },
    };
}

fn markdown(span: Span, context: Markdown.Context, options: Markdown.Options) Value {
    return Value{
        .markdown = .{
            .markdown = Markdown{ .span = span, .context = context },
            .options = options,
        },
    };
}
