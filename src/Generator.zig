// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Post = @import("Post.zig");
const Reporter = @import("Reporter.zig");
const Template = @import("Template.zig");
const Generator = @This();

allocator: Allocator,
reporter: *Reporter,
posts: []const Post,
templates: std.StringHashMap(Template),

pub fn generateFiles(self: Generator, dir: fs.Dir) !usize {
    try self.generateIndexHtml(dir, try self.getTemplate("index.html"));
    try self.generateIndexXml(dir, try self.getTemplate("index.xml"));
    var posts_dir = try dir.makeOpenPath("post", .{});
    defer posts_dir.close();
    const post_template = try self.getTemplate("post.html");
    for (self.posts) |post| try self.generatePost(posts_dir, post_template, post);
    return 0;
}

fn getTemplate(self: Generator, name: []const u8) !Template {
    return self.templates.get(name) orelse self.reporter.failRaw("{s}: template not found", .{name});
}

fn generateIndexHtml(self: Generator, dir: fs.Dir, template: Template) !void {
    var file = try dir.createFile("index.html", .{});
    defer file.close();
    var value = try Template.Value.init(self.allocator, .{
        .style_url = "style.css",
        .math = false,
        .analytics = false,
        .older = "#",
        .newer = "#",
        .home_url = false,
        .blog_url = "/",
    });
    defer value.deinit(self.allocator);
    var scope = Template.Scope{ .parent = null, .value = value };
    defer scope.deinit(self.allocator);
    try template.execute(self.allocator, &scope, self.reporter, file.writer());
}

fn generateIndexXml(self: Generator, dir: fs.Dir, template: Template) !void {
    _ = template;
    _ = dir;
    _ = self;
}

fn generatePost(self: Generator, dir: fs.Dir, template: Template, post: Post) !void {
    var post_dir = try dir.makeOpenPath(post.slug, .{});
    defer post_dir.close();
    var file = try post_dir.createFile("index.html", .{});
    defer file.close();
    var value = try Template.Value.init(self.allocator, .{
        .title = post.metadata.title,
        .description = post.metadata.description,
        .date = "The date",
        .article = post.source[post.markdown_offset..],
        .style_url = "../../style.css",
        .math = false,
        .analytics = false,
        .older = "#",
        .newer = "#",
        .home_url = false,
        .blog_url = "/",
    });
    defer value.deinit(self.allocator);
    var scope = Template.Scope{ .parent = null, .value = value };
    defer scope.deinit(self.allocator);
    try template.execute(self.allocator, &scope, self.reporter, file.writer());
}
