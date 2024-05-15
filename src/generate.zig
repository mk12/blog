// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module provides a function that generates all the files for the blog.
//! This is the least reusable part of the codebase.

const constants = @import("constants.zig");
const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Date = @import("Date.zig");
const Markdown = @import("Markdown.zig");
const Post = @import("Post.zig");
const Scanner = @import("Scanner.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Template = @import("Template.zig");
const Scope = Template.Scope;
const Value = Template.Value;

pub fn generate(
    arena: *ArenaAllocator,
    reporter: *Reporter,
    templates: std.StringHashMapUnmanaged(Value),
    posts: []const Post,
    files_to_generate: []const []const u8,
) !void {
    var state = struct {
        has_footnotes: Value,
        arena: ArenaAllocator,
        fn reset(self: *@This()) Allocator {
            self.has_footnotes.bool = false;
            _ = self.arena.reset(.retain_capacity);
            return self.arena.allocator();
        }
    }{
        .has_footnotes = Value{ .bool = false },
        .arena = std.heap.ArenaAllocator.init(arena.child_allocator),
    };
    defer state.arena.deinit();
    const allocator = arena.allocator();
    const post_values = try postValues(allocator, posts, &state.has_footnotes.bool);
    const scope = Scope.init(Value{ .dict = templates }).initChild(try Value.init(allocator, .{
        .site_url = constants.site_url,
        .current_date = date(Date.fromTimestamp(std.time.timestamp()), .rfc822),
        .posts = post_values,
        .recent_posts = post_values[0..10],
        .by_year = try groupPostsByYear(allocator, posts, post_values),
        .by_category = try groupPostsByCategory(allocator, posts, post_values),
        .has_footnotes = &state.has_footnotes,
    }));
    var src_dir = try fs.cwd().openDir(constants.src_dir, .{});
    defer src_dir.close();
    var out_dir = try fs.cwd().makeOpenPath(constants.out_dir, .{});
    defer out_dir.close();
    var post_dir = try fs.cwd().makeOpenPath(constants.out_post_dir, .{});
    defer post_dir.close();
    const post_template_value = templates.get("post.html") orelse
        return reporter.fail(constants.src_template_dir ++ "/post.html", Location.none, "template not found", .{});
    const post_template = post_template_value.template;
    if (files_to_generate.len == 0) {
        var walker = try fs.Dir.walk(src_dir, allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.basename[0] == '_') {
                if (entry.kind == .directory) {
                    var dir = walker.stack.pop().iter.dir;
                    dir.close();
                }
                continue;
            }
            if (entry.kind == .directory) {
                out_dir.makeDir(entry.path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                continue;
            }
            if (mem.eql(u8, fs.path.extension(entry.basename), ".md")) continue;
            try generateFile(state.reset(), reporter, out_dir, scope, entry);
        }
        for (posts, post_values) |post, value| {
            try generatePost(state.reset(), reporter, post_dir, post_template, post.slug, scope.initChild(value));
        }
    } else for (files_to_generate) |file| {
        const prefix = constants.src_dir ++ "/";
        if (file.len <= prefix.len or !mem.startsWith(u8, file, prefix)) return reporter.fail(file, Location.none, "file is not in " ++ prefix, .{});
        const path = file[prefix.len..];
        const dirname = fs.path.dirname(path);
        if (mem.eql(u8, fs.path.extension(file), ".md")) {
            const slug = Post.parseSlug(path);
            const value = for (posts, post_values) |post, value| {
                if (mem.eql(u8, post.slug, slug)) break value;
            } else return reporter.fail(file, Location.none, "could not find post", .{});
            try generatePost(state.reset(), reporter, post_dir, post_template, slug, scope.initChild(value));
        } else {
            const entry = blk: {
                const dir = if (dirname) |name| src_dir.openDir(name, .{}) catch |err| break :blk err else src_dir;
                const basename = fs.path.basename(path);
                const stat = dir.statFile(basename) catch |err| break :blk err;
                break :blk fs.Dir.Walker.WalkerEntry{ .dir = dir, .basename = basename, .path = path, .kind = stat.kind };
            } catch |err| return switch (err) {
                error.FileNotFound => reporter.fail(file, Location.none, "file not found", .{}),
                else => err,
            };
            if (dirname) |name| try out_dir.makePath(name);
            try generateFile(state.reset(), reporter, out_dir, scope, entry);
        }
    }
}

fn generateFile(allocator: Allocator, reporter: *Reporter, out_dir: fs.Dir, scope: Scope, entry: fs.Dir.Walker.WalkerEntry) !void {
    if (entry.kind != .file) {
        const path = try fs.path.join(allocator, &.{ constants.src_dir, entry.path });
        return reporter.fail(path, Location.none, "not a file", .{});
    }
    if (mem.eql(u8, entry.basename, ".DS_Store")) return;
    const extension = fs.path.extension(entry.basename);
    const is_phtml = mem.eql(u8, extension, ".phtml");
    if (is_phtml or mem.eql(u8, extension, ".html") or mem.eql(u8, extension, ".xml")) {
        var scanner = Scanner{
            .source = try entry.dir.readFileAlloc(allocator, entry.basename, constants.max_file_size),
            .filename = try fs.path.join(allocator, &.{ constants.src_dir, entry.path }),
            .reporter = reporter,
        };
        const page = try Template.parse(allocator, &scanner);
        // We use .phtml source files to indicate templating, but always use .php in output.
        var buf: [128]u8 = undefined;
        const path = if (is_phtml) try std.fmt.bufPrint(&buf, "{s}.php", .{entry.path[0 .. entry.path.len - ".phtml".len]}) else entry.path;
        var file = try out_dir.createFile(path, .{});
        defer file.close();
        var buffer = std.io.bufferedWriter(file.writer());
        try page.execute(allocator, reporter, buffer.writer(), MarkdownHooks{}, scope);
        try buffer.flush();
    } else {
        try entry.dir.copyFile(entry.basename, out_dir, entry.path, .{});
    }
}

fn generatePost(allocator: Allocator, reporter: *Reporter, post_dir: fs.Dir, template: Template, slug: []const u8, scope: Scope) !void {
    var filename: [64]u8 = undefined;
    var file = try post_dir.createFile(try std.fmt.bufPrint(&filename, "{s}.html", .{slug}), .{});
    defer file.close();
    var buffer = std.io.bufferedWriter(file.writer());
    try template.execute(allocator, reporter, buffer.writer(), MarkdownHooks{}, scope);
    try buffer.flush();
}

fn postValues(allocator: Allocator, posts: []const Post, out_has_footnotes: *bool) ![]Value {
    const values = try allocator.alloc(Value, posts.len);
    for (posts, values, 0..) |post, *item, i| {
        item.* = try Value.init(allocator, .{
            .url = try std.fmt.allocPrint(allocator, "/blog/post/{s}", .{post.slug}),
            .prev = if (i != 0) &values[i - 1] else null,
            .next = if (i + 1 != values.len) &values[i + 1] else null,
            .date_short = date(post.meta.date, .short),
            .date_long = date(post.meta.date, .long),
            .date_rfc822 = date(post.meta.date, .rfc822),
            .title = markdown(post.meta.title, post.context, .{ .is_inline = true }),
            .subtitle = markdown(post.meta.subtitle, post.context, .{ .is_inline = true }),
            .excerpt = markdown(post.body, post.context, .{ .first_block_only = true }),
            .content = markdown(post.body, post.context, .{ .shift_heading_level = 1, .highlight_code = true, .auto_heading_ids = true, .out_has_footnotes = out_has_footnotes }),
            .rss_content = markdown(post.body, post.context, .{ .hook_options = &use_absolute_urls }),
        });
    }
    return values;
}

fn groupPostsByYear(allocator: Allocator, posts: []const Post, values: []Value) ![]Value {
    var groups = std.ArrayList(Value).init(allocator);
    var start: usize = 0;
    var year = posts[0].meta.date.year;
    for (posts, 0..) |post, i| if (year != post.meta.date.year) {
        try groups.append(try yearGroup(allocator, year, values[start..i]));
        start = i;
        year = post.meta.date.year;
    };
    try groups.append(try yearGroup(allocator, year, values[start..]));
    return groups.items;
}

fn yearGroup(allocator: Allocator, year: u16, values: []Value) !Value {
    return Value.init(allocator, .{ .year = try std.fmt.allocPrint(allocator, "{}", .{year}), .posts = values });
}

fn groupPostsByCategory(allocator: Allocator, posts: []const Post, values: []const Value) ![]Value {
    var map = std.StringHashMap(std.ArrayListUnmanaged(Value)).init(allocator);
    var categories = std.ArrayList([]const u8).init(allocator);
    for (posts, values) |post, *value| {
        const result = try map.getOrPut(post.meta.category);
        if (!result.found_existing) {
            try categories.append(post.meta.category);
            result.value_ptr.* = .{};
        }
        try result.value_ptr.append(allocator, Value{ .pointer = value });
    }
    mem.sort([]const u8, categories.items, {}, cmpStringsAscending);
    const groups = try allocator.alloc(Value, categories.items.len);
    for (groups, categories.items) |*group, category| group.* = try Value.init(allocator, .{
        .category = category,
        .posts = map.get(category).?.items,
    });
    return groups;
}

fn cmpStringsAscending(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.order(u8, lhs, rhs) == .lt;
}

fn date(d: Date, style: Date.Style) Value {
    return Value{ .date = .{ .date = d, .style = style } };
}

fn markdown(text: []const u8, context: Markdown.Context, options: Markdown.Options) Value {
    return Value{ .markdown = .{ .markdown = Markdown{ .text = text, .context = context }, .options = options } };
}

const HookOptions = struct { absolute_urls: bool = false };
const use_absolute_urls = HookOptions{ .absolute_urls = true };

const MarkdownHooks = struct {
    pub fn writeUrl(self: MarkdownHooks, writer: anytype, context: Markdown.HookContext, url: []const u8) !void {
        _ = self;
        return writeUrlOrImage(writer, context, url, false);
    }

    pub fn writeImage(self: MarkdownHooks, writer: anytype, context: Markdown.HookContext, url: []const u8) !void {
        _ = self;
        return writeUrlOrImage(writer, context, url, true);
    }

    fn writeUrlOrImage(writer: anytype, context: Markdown.HookContext, url: []const u8, is_image: bool) !void {
        const options_ptr: ?*const HookOptions = @ptrCast(context.options.hook_options);
        const options = if (options_ptr) |ptr| ptr.* else HookOptions{};
        if (url.len == 0) return context.fail("{s}: unexpected empty URL", .{url});
        const has_protocol = mem.indexOf(u8, url, "://") != null;
        const hash_idx = mem.indexOfScalar(u8, url, '#') orelse url.len;
        if (has_protocol or hash_idx == 0) return writeNonSvg(writer, is_image, false, "{s}", .{url});
        const fragment = url[hash_idx..];
        var buffer: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const cwd_relative = try fs.path.resolve(fba.allocator(), &.{ context.filename, "..", url[0..hash_idx] });
        fs.cwd().access(cwd_relative, .{}) catch |err| return context.fail("{s}: {s}", .{ url, @errorName(err) });
        const prefix = constants.src_site_dir ++ "/";
        if (!mem.startsWith(u8, cwd_relative, prefix)) return context.fail("{s}: path is outside website", .{url});
        const site_relative = cwd_relative[prefix.len..];
        const extension = fs.path.extension(site_relative);
        if (is_image and mem.eql(u8, extension, ".svg")) {
            const file = try fs.cwd().openFile(cwd_relative, .{});
            defer file.close();
            var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
            return fifo.pump(file.reader(), writer);
        }
        const remove = if (mem.eql(u8, extension, ".md")) extension.len else 0;
        const final_site_relative = site_relative[0 .. site_relative.len - remove];
        return writeNonSvg(writer, is_image, options.absolute_urls, "/{s}{s}", .{ final_site_relative, fragment });
    }

    fn writeNonSvg(writer: anytype, is_image: bool, make_absolute: bool, comptime format: []const u8, args: anytype) !void {
        if (is_image) try writer.writeAll("<img src=\"");
        if (make_absolute) try writer.writeAll(constants.site_url);
        try writer.print(format, args);
        if (is_image) try writer.writeAll("\">");
    }
};
