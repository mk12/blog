// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const EnumFieldStruct = std.enums.EnumFieldStruct;
const Post = @import("Post.zig");
const Reporter = @import("Reporter.zig");
const Template = @import("Template.zig");
const Scope = Template.Scope;
const Value = Template.Value;

pub fn generate(args: struct {
    allocator: Allocator,
    reporter: *Reporter,
    out_dir: fs.Dir,
    templates: std.StringHashMap(Template),
    posts: []const Post,
    base_url: ?[]const u8,
    home_url: ?[]const u8,
    font_url: ?[]const u8,
    analytics: ?[]const u8,
}) !usize {
    const allocator = args.allocator;
    const reporter = args.reporter;
    const dirs = try Dirs.init(args.out_dir);
    defer dirs.close();
    const templates = try Templates.init(reporter, args.templates);
    const pages = std.enums.values(Page);
    const posts = args.posts;

    var globals = try Value.init(allocator, .{
        .author = "Mitchell Kember",
        .style_url = "style.css", // link.to
        .blog_url = "index.html", // link to
        .home_url = args.home_url,
        .analytics = args.analytics,
        .year = "2023", // TODO
    });
    defer globals.deinitRecursive(allocator);
    // TODO make scopes more ergonomic
    var scope = Scope{ .parent = null, .value = globals };
    defer scope.deinit(allocator);

    for (pages) |page| try generatePage(allocator, reporter, dirs, templates, &scope, posts, page);
    for (posts) |post| try generatePost(allocator, reporter, dirs, templates, &scope, post);

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
                return reporter.failRaw("{s}: template not found", .{field.name});
        return result;
    }
};

const Page = enum {
    @"index.html",
    @"index.xml",
    @"post/index.html",
    @"categories/index.html",
};

fn generatePage(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Dirs,
    templates: Templates,
    global_scope: *const Scope,
    posts: []const Post,
    page: Page,
) !void {
    _ = global_scope;
    _ = templates;
    _ = dirs;
    _ = posts;
    _ = reporter;
    _ = allocator;
    std.debug.print("skipping {s}\n", .{@tagName(page)});
    //     var file = try dir.createFile("index.html", .{});
    //     defer file.close();
    //     var value = try Template.Value.init(allocator, .{
    //         .style_url = "style.css",
    //         .math = false,
    //         .analytics = false,
    //         .older = "#",
    //         .newer = "#",
    //         .home_url = false,
    //         .blog_url = "/",
    //     });
    //     defer value.deinit(allocator);
    //     var scope = Template.Scope{ .parent = null, .value = value };
    //     defer scope.deinit(allocator);
    //     try template.execute(allocator, &scope, reporter, file.writer());
}

fn generatePost(
    allocator: Allocator,
    reporter: *Reporter,
    dirs: Dirs,
    templates: Templates,
    global_scope: *const Scope,
    post: Post,
) !void {
    var dir = try dirs.@"/post".makeOpenPath(post.slug, .{});
    defer dir.close();
    var file = try dir.createFile("index.html", .{});
    defer file.close();
    var date_buf: [32]u8 = undefined;
    const date = switch (post.metadata.status) {
        .draft => "DRAFT",
        .published => |date| try std.fmt.bufPrint(&date_buf, "{long}", .{date.fmt()}),
    };
    var value = try Value.init(allocator, .{
        .title = post.metadata.title,
        .description = post.metadata.description,
        .date = date,
        // TODO render markdown
        .article = post.source[post.markdown_offset..],
        .math = false,
        .older = "#",
        .newer = "#",
        // TODO style_url is fixed only if absolute URLs
        .style_url = "../../style.css",
    });
    defer value.deinitRecursive(allocator);
    var scope = Template.Scope{ .parent = global_scope, .value = value };
    defer scope.deinit(allocator);
    try templates.@"post.html".execute(allocator, reporter, file.writer(), &scope);
}
