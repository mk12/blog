// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module provides a function that generates all the files for the blog.
//! This is the least reusable part of the codebase.

const constants = @import("constants.zig");
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Date = @import("Date.zig");
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
    out_dir: []const u8,
    templates: std.StringHashMap(Template),
    posts: []const Post,
    base_url: ?[]const u8,
    home_url: ?[]const u8,
    font_url: ?[]const u8,
    analytics: ?[]const u8,
}) !void {
    const allocator = args.arena.allocator();
    var dirs = try Directories.init(args.out_dir);
    defer dirs.close();
    var resolver = Resolver{ .allocator = allocator, .dirs = &dirs };
    const base_url = try BaseUrl.init(args.reporter, args.base_url);
    const file_ctx = FileContext{
        .reporter = args.reporter,
        .dirs = dirs, // TODO &dirs? weird that "owned" here but other stack copy pointer to by resolver...
        .templates = try Templates.init(args.reporter, args.templates),
        .resolver = &resolver,
        .base_url = base_url,
        .parent = Scope.init(try Value.init(allocator, .{
            .author = "Mitchell Kember",
            .base_url = base_url.relative,
            .home_url = args.home_url,
            .analytics = if (args.analytics) |path| try fs.cwd().readFileAlloc(allocator, path, constants.max_file_size) else null,
        })),
    };
    var per_file_arena = std.heap.ArenaAllocator.init(args.arena.child_allocator);
    defer per_file_arena.deinit();
    const per_file_allocator = per_file_arena.allocator();
    try symlink(per_file_allocator, dirs.@"/", constants.asset_dir ++ "/css/style.css", "style.css");
    for (std.enums.values(Page)) |page| {
        _ = per_file_arena.reset(.retain_capacity);
        try generatePage(per_file_allocator, file_ctx, args.posts, page);
    }
    for (args.posts, 0..) |post, i| {
        _ = per_file_arena.reset(.retain_capacity);
        try generatePost(per_file_allocator, file_ctx, post, Neighbors.init(args.posts, i));
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

const Resolver = struct {
    allocator: Allocator,
    dirs: *const Directories,
    img_map: std.StringHashMapUnmanaged(void) = .{},
    svg_map: std.StringArrayHashMapUnmanaged([]const u8) = .{},

    const Result = union(enum) { not_found, url: []const u8, svg: []const u8 };

    fn resolve(self: *Resolver, url_builder: UrlBuilder, src_path: []const u8, url: []const u8) !Result {
        if (mem.indexOf(u8, url, "://")) |_| return .{ .url = url };
        const src_dir = fs.path.dirname(src_path).?;
        const path = try fs.path.resolve(self.allocator, &.{ src_dir, url });
        if (descend(path, constants.post_dir)) |post_path| {
            const hash_idx = mem.indexOfScalar(u8, post_path, '#') orelse post_path.len;
            const slug = Post.parseSlug(post_path[0..hash_idx]);
            return .{ .url = try url_builder.postFragment(slug, post_path[hash_idx..]) };
        }
        if (descend(path, constants.asset_dir)) |asset_path| {
            if (descend(asset_path, "img")) |filename| {
                const result = try self.img_map.getOrPut(self.allocator, filename);
                if (!result.found_existing) try symlink(self.allocator, self.dirs.@"/img", path, filename);
                return .{ .url = try url_builder.fmt("/img/{s}", .{filename}) };
            }
            if (descend(asset_path, "svg")) |filename| {
                const result = try self.svg_map.getOrPut(self.allocator, filename);
                if (!result.found_existing) {
                    const data = try fs.cwd().readFileAlloc(self.allocator, path, constants.max_file_size);
                    result.value_ptr.* = mem.trimRight(u8, data, "\n");
                }
                return .{ .svg = result.value_ptr.* };
            }
        }
        return .not_found;
    }
};

fn descend(path: []const u8, comptime dirname: []const u8) ?[]const u8 {
    const prefix = dirname ++ "/";
    return if (mem.startsWith(u8, path, prefix)) path[prefix.len..] else null;
}

fn symlink(allocator: Allocator, dir: fs.Dir, cwd_target_path: []const u8, sym_link_path: []const u8) !void {
    const target_path = try fs.cwd().realpathAlloc(allocator, cwd_target_path);
    dir.symLink(target_path, sym_link_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const BaseUrl = struct {
    absolute: []const u8 = "", // e.g. https://example.com/blog
    relative: []const u8 = "", // e.g. /blog

    fn init(reporter: *Reporter, base: ?[]const u8) !BaseUrl {
        const absolute = base orelse return BaseUrl{};
        if (absolute.len == 0) return BaseUrl{};
        const sep = "://";
        const sep_idx = mem.indexOf(u8, absolute, sep) orelse
            return reporter.fail("BASE_URL: \"{s}\": missing \"{s}\"", .{ absolute, sep });
        const slash_idx = mem.indexOfScalarPos(u8, absolute, sep_idx + sep.len, '/') orelse absolute.len;
        return BaseUrl{ .absolute = absolute, .relative = absolute[slash_idx..] };
    }
};

const UrlBuilder = struct {
    allocator: Allocator,
    base_url: []const u8,
    // Note: If in same page #foo, should render correctly when it's excerpt on main page too.
    // store destination here too
    // then can check whether same file #foo should just be #foo or should be full /path/to#foo
    // (and in principle could change to use ../rel.html links easily).

    fn fmt(self: UrlBuilder, comptime format: []const u8, args: anytype) ![]const u8 {
        if (format[0] != '/') @compileError(format ++ ": does not start with slash");
        return std.fmt.allocPrint(self.allocator, "{s}" ++ format, .{self.base_url} ++ args);
    }

    fn post(self: UrlBuilder, slug: []const u8) ![]const u8 {
        return self.fmt("/post/{s}/", .{slug});
    }

    fn postFragment(self: UrlBuilder, slug: []const u8, fragment: []const u8) ![]const u8 {
        return self.fmt("/post/{s}/{s}", .{ slug, fragment });
    }
};

const Hooks = struct {
    resolver: *Resolver,
    url_builder: UrlBuilder,

    pub fn writeUrl(self: *Hooks, writer: anytype, context: Markdown.HookContext, url: []const u8) !void {
        switch (try self.resolver.resolve(self.url_builder, context.filename, url)) {
            .url => |resolved_url| try writer.writeAll(resolved_url),
            .svg => return context.fail("{s}: cannot link to SVG", .{url}),
            .not_found => return context.fail("{s}: cannot resolve URL", .{url}),
        }
    }

    pub fn writeImage(self: *Hooks, writer: anytype, context: Markdown.HookContext, url: []const u8) !void {
        switch (try self.resolver.resolve(self.url_builder, context.filename, url)) {
            .url => |src| try writer.print("<img src=\"{s}\">", .{src}),
            .svg => |svg| try writer.writeAll(svg),
            .not_found => return context.fail("{s}: cannot resolve URL", .{url}),
        }
    }
};

const FileContext = struct {
    reporter: *Reporter,
    dirs: Directories,
    templates: Templates,
    resolver: *Resolver,
    base_url: BaseUrl,
    parent: Scope, // TODO "root_scope"?
};

const Page = enum {
    @"/index.html",
    @"/index.xml",
    @"/post/index.html",
    @"/categories/index.html",
};

fn generatePage(allocator: Allocator, ctx: FileContext, posts: []const Post, page: Page) !void {
    const file = switch (page) {
        inline else => |p| try @field(ctx.dirs, fs.path.dirname(@tagName(p)).?)
            .createFile(comptime fs.path.basename(@tagName(p)), .{}),
    };
    defer file.close();
    const template = switch (page) {
        .@"/index.html" => ctx.templates.@"index.html",
        .@"/index.xml" => ctx.templates.@"feed.xml",
        .@"/post/index.html", .@"/categories/index.html" => ctx.templates.@"listing.html",
    };
    const url_builder = UrlBuilder{
        .allocator = allocator,
        .base_url = switch (page) {
            .@"/index.xml" => ctx.base_url.absolute,
            else => ctx.base_url.relative,
        },
    };
    const variables = switch (page) {
        .@"/index.html" => try Value.init(allocator, .{
            .title = "Mitchell Kember",
            .posts = try recentPostSummaries(allocator, url_builder, posts),
        }),
        .@"/post/index.html" => try Value.init(allocator, .{
            .title = "Post Archive", // TODO <title> should have my name
            .groups = try groupPostsByYear(allocator, url_builder, posts),
        }),
        .@"/categories/index.html" => try Value.init(allocator, .{
            .title = "Categories", // TODO <title> should have my name
            .groups = try groupPostsByCategory(allocator, url_builder, posts),
        }),
        .@"/index.xml" => try Value.init(allocator, .{
            .title = "Mitchell Kember",
            .posts = .{}, // TODO
            .last_build_date = "", // TODO
            .base_url = ctx.base_url.absolute,
        }),
    };
    var scope = ctx.parent.initChild(variables);
    var hooks = Hooks{ .url_builder = url_builder, .resolver = ctx.resolver };
    var buffer = std.io.bufferedWriter(file.writer());
    try template.execute(allocator, ctx.reporter, buffer.writer(), &hooks, &scope);
    try buffer.flush();
}

const num_recent = 10;
const Summary = struct { date: Value, title: Value, href: []const u8, excerpt: Value };

fn recentPostSummaries(allocator: Allocator, url_builder: UrlBuilder, posts: []const Post) ![num_recent]Summary {
    _ = allocator;
    var summaries: [num_recent]Summary = undefined;
    for (0..num_recent) |i| {
        const post = posts[i];
        summaries[i] = Summary{
            .date = date(post.meta.status, .long),
            .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
            .href = try url_builder.post(post.slug),
            .excerpt = markdown(post.body, post.context, .{ .first_block_only = true }),
        };
    }
    return summaries;
}

const Group = struct { name: []const u8, posts: []Entry };

const Entry = struct {
    date: Value,
    title: Value,
    href: []const u8,

    fn init(allocator: Allocator, post: Post, url_builder: UrlBuilder) !Entry {
        _ = allocator;
        return Entry{
            .date = date(post.meta.status, .short),
            .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
            .href = try url_builder.post(post.slug),
        };
    }
};

const unset_year: u16 = 0;
const draft_year: u16 = 1;

fn groupPostsByYear(allocator: Allocator, url_builder: UrlBuilder, posts: []const Post) ![]Group {
    var groups = std.ArrayList(Group).init(allocator);
    var year: u16 = unset_year;
    var entries = std.ArrayList(Entry).init(allocator);
    for (posts) |post| {
        const post_year = switch (post.meta.status) {
            .draft => draft_year,
            .published => |d| d.year,
        };
        try flushYearGroup(allocator, &groups, year, &entries, post_year);
        year = post_year;
        try entries.append(try Entry.init(allocator, post, url_builder));
    }
    try flushYearGroup(allocator, &groups, year, &entries, unset_year);
    return groups.items;
}

fn flushYearGroup(allocator: Allocator, groups: *std.ArrayList(Group), year: u16, entries: *std.ArrayList(Entry), post_year: u16) !void {
    if (year == post_year or entries.items.len == 0) return;
    const name = switch (year) {
        unset_year => unreachable,
        draft_year => "Drafts",
        else => |y| try std.fmt.allocPrint(allocator, "{}", .{y}),
    };
    try groups.append(Group{ .name = name, .posts = try entries.toOwnedSlice() });
}

fn groupPostsByCategory(allocator: Allocator, url_builder: UrlBuilder, posts: []const Post) ![]Group {
    var map = std.StringHashMap(std.ArrayListUnmanaged(Entry)).init(allocator);
    var categories = std.ArrayList([]const u8).init(allocator);
    for (posts) |post| {
        const result = try map.getOrPut(post.meta.category);
        if (!result.found_existing) {
            try categories.append(post.meta.category);
            result.value_ptr.* = .{};
        }
        try result.value_ptr.append(allocator, try Entry.init(allocator, post, url_builder));
    }
    mem.sort([]const u8, categories.items, {}, cmpStringsAscending);
    var groups = try std.ArrayList(Group).initCapacity(allocator, categories.items.len);
    for (categories.items) |category| try groups.append(Group{
        .name = category,
        .posts = map.get(category).?.items,
    });
    return groups.items;
}

fn cmpStringsAscending(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.order(u8, lhs, rhs) == .lt;
}

const Neighbors = struct {
    newer: ?*const Post,
    older: ?*const Post,

    fn init(posts: []const Post, i: usize) Neighbors {
        return Neighbors{
            .newer = if (i > 0) &posts[i - 1] else null,
            .older = if (i < posts.len - 1) &posts[i + 1] else null,
        };
    }
};

fn generatePost(allocator: Allocator, ctx: FileContext, post: Post, neighbors: Neighbors) !void {
    var dir = try ctx.dirs.@"/post".makeOpenPath(post.slug, .{});
    defer dir.close();
    var file = try dir.createFile("index.html", .{});
    defer file.close();
    const url_builder = UrlBuilder{ .allocator = allocator, .base_url = ctx.base_url.relative };
    const variables = try Value.init(allocator, .{
        .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
        .subtitle = markdown(post.meta.subtitle, post.context, .{ .is_inline = true }),
        .date = date(post.meta.status, .long),
        .content = markdown(post.body, post.context, .{ .shift_heading_level = 1, .highlight_code = true, .auto_heading_ids = true }),
        .newer = try if (neighbors.newer) |newer| url_builder.post(newer.slug) else url_builder.fmt("/", .{}),
        .older = try if (neighbors.older) |older| url_builder.post(older.slug) else url_builder.fmt("/post/", .{}),
    });
    var scope = ctx.parent.initChild(variables);
    var hooks = Hooks{ .url_builder = url_builder, .resolver = ctx.resolver };
    var buffer = std.io.bufferedWriter(file.writer());
    try ctx.templates.@"post.html".execute(allocator, ctx.reporter, buffer.writer(), &hooks, &scope);
    try buffer.flush();
}

fn date(status: Status, style: Date.Style) Value {
    return switch (status) {
        .draft => Value{ .string = "Draft" },
        .published => |d| Value{ .date = .{ .date = d, .style = style } },
    };
}

fn markdown(text: []const u8, context: Markdown.Context, options: Markdown.Options) Value {
    return Value{
        .markdown = .{
            .markdown = Markdown{ .text = text, .context = context },
            .options = options,
        },
    };
}
