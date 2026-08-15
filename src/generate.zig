// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module provides a function that generates all the files for the blog.
//! This is the least reusable part of the codebase.

const constants = @import("constants.zig");
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Date = @import("Date.zig");
const Document = @import("Document.zig");
const Markdown = @import("Markdown.zig");
const Scanner = @import("Scanner.zig");
const Reporter = @import("Reporter.zig");
const Location = Reporter.Location;
const Template = @import("Template.zig");
const Scope = Template.Scope;
const Value = Template.Value;

pub fn generate(
    io: std.Io,
    arena: *ArenaAllocator,
    reporter: *Reporter,
    templates: std.StringHashMapUnmanaged(Value),
    posts: []const Document,
    crafts: []const Document,
    books: []const Document,
    recipes: []const Document,
    files_to_generate: []const []const u8,
) !void {
    var per_page_arena = std.heap.ArenaAllocator.init(arena.child_allocator);
    defer per_page_arena.deinit();
    const allocator = arena.allocator();
    const per_page_allocator = per_page_arena.allocator();
    var state = State{};
    var document_map: std.StringHashMapUnmanaged(DVT) = .empty;
    const post_values = try postValues(allocator, reporter, &state, &document_map, templates, posts);
    const craft_values = try documentValues(allocator, reporter, &state, &document_map, templates, crafts);
    const book_values = try documentValues(allocator, reporter, &state, &document_map, templates, books);
    const recipe_values = try documentValues(allocator, reporter, &state, &document_map, templates, recipes);
    const all_documents = [_][]const Document{ posts, crafts, books, recipes };
    const all_values = [_][]const Value{ post_values, craft_values, book_values, recipe_values };
    const documents = try interleaveDocuments(allocator, all_documents, all_values);
    var root_value = try Value.init(allocator, .{
        .true = true,
        .false = false,
        .site_url = constants.site_url,
        .current_date = date(Date.fromTimestamp(std.Io.Clock.real.now(io).toSeconds()), .rfc822),
        .posts = post_values,
        .crafts = craft_values,
        .books = book_values,
        .recipes = recipe_values,
        .documents = documents,
        .has_footnotes = &state.has_footnotes,
    });
    {
        var iter = templates.iterator();
        while (iter.next()) |entry| try root_value.dict.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
    const scope = Scope.init(root_value);
    var src_dir = try std.Io.Dir.cwd().openDir(io, constants.src_dir, .{});
    defer src_dir.close(io);
    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, constants.out_dir, .{});
    defer out_dir.close(io);
    if (files_to_generate.len == 0) {
        var walker = try src_dir.walkSelectively(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.basename[0] == '_') continue;
            if (entry.kind == .directory) {
                try walker.enter(io, entry);
                out_dir.createDirPath(io, entry.path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                continue;
            }
            _ = per_page_arena.reset(.retain_capacity);
            try generateFile(per_page_allocator, io, reporter, out_dir, state.reset(), templates, document_map, scope, try Entry.from(per_page_allocator, entry));
        }
    } else for (files_to_generate) |path| {
        const prefix = constants.src_dir ++ "/";
        if (path.len <= prefix.len or !mem.startsWith(u8, path, prefix))
            return reporter.fail(path, Location.none, "file is not in " ++ prefix, .{});
        const rel_path = path[prefix.len..];
        const dirname = std.fs.path.dirname(rel_path);
        const entry = blk: {
            const dir = if (dirname) |name| src_dir.openDir(io, name, .{}) catch |err| break :blk err else src_dir;
            const basename = std.fs.path.basename(path);
            const stat = dir.statFile(io, basename, .{ .follow_symlinks = false }) catch |err| break :blk err;
            break :blk Entry{ .dir = dir, .basename = basename, .path = path, .rel_path = rel_path, .kind = stat.kind };
        } catch |err| return switch (err) {
            error.FileNotFound => reporter.fail(path, Location.none, "file not found", .{}),
            else => err,
        };
        if (dirname) |name| try out_dir.createDirPath(io, name);
        _ = per_page_arena.reset(.retain_capacity);
        try generateFile(per_page_allocator, io, reporter, out_dir, state.reset(), templates, document_map, scope, entry);
    }
}

const State = struct {
    has_footnotes: Value = .{ .bool = false },

    fn reset(self: *@This()) *@This() {
        self.has_footnotes.bool = false;
        return self;
    }
};

const Entry = struct {
    dir: std.Io.Dir,
    basename: []const u8,
    path: []const u8,
    rel_path: []const u8,
    kind: std.Io.File.Kind,

    fn from(allocator: Allocator, entry: std.Io.Dir.Walker.Entry) !Entry {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ constants.src_dir, entry.path });
        return Entry{ .dir = entry.dir, .basename = entry.basename, .path = path, .rel_path = entry.path, .kind = entry.kind };
    }
};

const DVT = struct {
    doc: *const Document,
    val: Value,
    template: *const Template,
};

fn generateFile(
    allocator: Allocator,
    io: std.Io,
    reporter: *Reporter,
    out_dir: std.Io.Dir,
    state: *State,
    templates: std.StringHashMapUnmanaged(Value),
    documents: std.StringHashMapUnmanaged(DVT),
    parent_scope: Scope,
    entry: Entry,
) !void {
    return generateFileImpl(allocator, io, reporter, out_dir, state, templates, documents, parent_scope, entry) catch |err| {
        if (err == error.ErrorWasReported) reporter.addNote(entry.path, Location.none, "while compiling this file", .{});
        return err;
    };
}

fn generateFileImpl(
    allocator: Allocator,
    io: std.Io,
    reporter: *Reporter,
    out_dir: std.Io.Dir,
    state: *State,
    templates: std.StringHashMapUnmanaged(Value),
    documents: std.StringHashMapUnmanaged(DVT),
    parent_scope: Scope,
    entry: Entry,
) !void {
    if (entry.kind != .file) return reporter.fail(entry.path, Location.none, "not a file", .{});
    if (mem.eql(u8, entry.basename, ".DS_Store")) return;
    const extension = std.fs.path.extension(entry.basename);
    const is_md = mem.eql(u8, extension, ".md");
    const is_phtml = mem.eql(u8, extension, ".phtml");
    const needs_processing = is_md or is_phtml or mem.eql(u8, extension, ".html") or mem.eql(u8, extension, ".rss");
    if (!needs_processing) {
        blk: {
            const dst_stat = out_dir.statFile(io, entry.rel_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :blk,
                else => return err,
            };
            const src_stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
            if (src_stat.mtime.nanoseconds <= dst_stat.mtime.nanoseconds) return;
        }
        return entry.dir.copyFile(entry.basename, out_dir, entry.rel_path, io, .{});
    }
    const template, const dict, const opt_doc = blk: {
        if (documents.get(entry.path)) |dvt| break :blk .{ dvt.template, dvt.val.dict, dvt.doc };
        var dict: std.StringHashMapUnmanaged(Value) = .empty;
        try insertPathInfo(allocator, &dict, entry.path);
        var scanner = Scanner{
            .source = try entry.dir.readFileAlloc(io, entry.basename, allocator, constants.max_file_size),
            .filename = entry.path,
            .reporter = reporter,
        };
        if (!is_md) break :blk .{ &try Template.parse(allocator, &scanner), dict, null };
        const doc = &try Document.parse(allocator, &scanner, .{ .default_template = "page.html" });
        try insertDocumentContent(allocator, &dict, doc, state);
        try doc.insertMetadata(allocator, &dict);
        break :blk .{ try getDocumentTemplate(reporter, templates, doc), dict, doc };
    };
    const rel_path = if (is_md)
        try changeExtension(allocator, entry.rel_path, ".html")
    else if (is_phtml)
        try changeExtension(allocator, entry.rel_path, ".php")
    else
        entry.rel_path;
    var file = try out_dir.createFile(io, rel_path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    const scope = parent_scope.initChild(Value{ .dict = dict });
    const hooks = MarkdownHooks{ .allocator = allocator, .io = io, .templates = templates, .scope = scope };
    template.execute(allocator, reporter, writer, hooks, scope) catch |err| {
        if (err == error.ErrorWasReported) if (opt_doc) |doc| addTemplateSourceNote(reporter, doc);
        return err;
    };
    try writer.flush();
}

fn getDocumentTemplate(reporter: *Reporter, templates: std.StringHashMapUnmanaged(Value), doc: *const Document) !*const Template {
    const result = getTemplate(reporter, templates, doc.template);
    if (result == error.ErrorWasReported) addTemplateSourceNote(reporter, doc);
    return result;
}

fn getTemplate(reporter: *Reporter, templates: std.StringHashMapUnmanaged(Value), filename: []const u8) !*const Template {
    if (templates.getPtr(filename)) |value| return &value.template;
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ constants.src_template_dir, filename });
    return reporter.fail(path, Location.none, "template not found", .{});
}

fn addTemplateSourceNote(reporter: *Reporter, doc: *const Document) void {
    if (doc.default_template)
        reporter.addNote(doc.context.filename, Location.none, "template \"{s}\" used by default", .{doc.template})
    else
        reporter.addNote(doc.context.filename, Location.fromPtr(doc.context.source, doc.template.ptr), "template \"{s}\" selected here", .{doc.template});
}

// TODO: unify postValues and documentValues some more.
fn postValues(allocator: Allocator, reporter: *Reporter, state: *State, document_map: *std.StringHashMapUnmanaged(DVT), templates: std.StringHashMapUnmanaged(Value), posts: []const Document) ![]Value {
    const values = try allocator.alloc(Value, posts.len);
    for (posts, values, 0..) |*post, *item, i| {
        item.* = try Value.init(allocator, .{
            .prev = if (i != 0) &values[i - 1] else null,
            .next = if (i + 1 != values.len) &values[i + 1] else null,
            .date_ymd = date(post.date.?, .ymd),
            .date_short = date(post.date.?, .short),
            .date_long = date(post.date.?, .long),
            .date_rfc822 = date(post.date.?, .rfc822),
            .excerpt = markdown(post.body, post.context, .{ .first_block_only = true }),
            .post_content = markdown(post.body, post.context, .{ .shift_heading_level = 1, .highlight_code = true, .auto_heading_ids = true, .out_has_footnotes = &state.has_footnotes.bool }),
            .rss_content = if (post.date.?.sortKey() >= constants.rss_cutoff.sortKey())
                markdown(post.body, post.context, .{ .hook_options = &use_absolute_urls })
            else
                null,
        });
        try insertPathInfo(allocator, &item.dict, post.path());
        try post.insertMetadata(allocator, &item.dict);
        const template = try getDocumentTemplate(reporter, templates, post);
        try insertTemplateDefs(allocator, &item.dict, template);
        try document_map.put(allocator, post.path(), DVT{ .doc = post, .val = item.*, .template = template });
    }
    return values;
}

fn documentValues(allocator: Allocator, reporter: *Reporter, state: *State, document_map: *std.StringHashMapUnmanaged(DVT), templates: std.StringHashMapUnmanaged(Value), documents: []const Document) ![]Value {
    const values = try allocator.alloc(Value, documents.len);
    for (documents, values, 0..) |*doc, *item, i| {
        item.* = try Value.init(allocator, .{
            .prev = if (i != 0) &values[i - 1] else null,
            .next = if (i + 1 != values.len) &values[i + 1] else null,
            .date_ymd = date(doc.date.?, .ymd),
            .date_rfc822 = date(doc.date.?, .rfc822),
            .rss_content = if (doc.date.?.sortKey() >= constants.rss_cutoff.sortKey())
                markdown(doc.body, doc.context, .{ .hook_options = &use_absolute_urls })
            else
                null,
        });
        try insertPathInfo(allocator, &item.dict, doc.path());
        try insertDocumentContent(allocator, &item.dict, doc, state);
        try doc.insertMetadata(allocator, &item.dict);
        const template = try getDocumentTemplate(reporter, templates, doc);
        try insertTemplateDefs(allocator, &item.dict, template);
        try document_map.put(allocator, doc.path(), DVT{ .doc = doc, .val = item.*, .template = template });
    }
    return values;
}

fn insertTemplateDefs(allocator: Allocator, dict: *std.StringHashMapUnmanaged(Value), template: *const Template) !void {
    try dict.put(allocator, "__template__", Value{ .dict = template.definitions });
}

fn insertDocumentContent(allocator: Allocator, dict: *std.StringHashMapUnmanaged(Value), doc: *const Document, state: *State) !void {
    const stem = std.fs.path.stem(doc.template);
    const shift_heading_level: i8 = if (mem.eql(u8, stem, "base") or mem.eql(u8, stem, "page")) 0 else 1;
    try dict.put(
        allocator,
        try std.fmt.allocPrint(allocator, "{s}_content", .{stem}),
        markdown(doc.body, doc.context, .{ .shift_heading_level = shift_heading_level, .highlight_code = true, .auto_heading_ids = true, .out_has_footnotes = &state.has_footnotes.bool }),
    );
}

fn insertPathInfo(allocator: Allocator, dict: *std.StringHashMapUnmanaged(Value), path: []const u8) !void {
    const slug, const index = Document.parseSlug(path);
    try dict.put(allocator, "index", Value{ .bool = index });
    try dict.put(allocator, "slug", Value{ .string = slug });
    const parent = path[0 .. slug.ptr - path.ptr];
    const parent_slug = if (mem.count(u8, parent, "/") > constants.src_site_depth)
        Value{ .string = std.fs.path.basename(parent) }
    else
        Value.null;
    try dict.put(allocator, "parent_slug", parent_slug);
    const url = urlFromPath(path);
    const section = sectionFromPath(path);
    const feed_url = getFeedUrl(url, section);
    if (url) |string| try dict.put(allocator, "url", Value{ .string = string });
    if (feed_url) |string| try dict.put(allocator, "feed_url", Value{ .string = string });
    if (section) |string| {
        try dict.put(allocator, "section", Value{ .string = string });
        var title = try allocator.dupe(u8, string);
        title[0] = std.ascii.toUpper(title[0]);
        try dict.put(allocator, "section_title", Value{ .string = title });
    }
}

const num_doc_types = constants.num_doc_types;
fn interleaveDocuments(allocator: Allocator, documents: [num_doc_types][]const Document, values: [num_doc_types][]const Value) ![]Value {
    var result: std.ArrayList(Value) = .empty;
    var indexes = [_]usize{0} ** num_doc_types;
    var done = std.bit_set.IntegerBitSet(num_doc_types).initEmpty();
    while (true) {
        var keys = [_]u64{0} ** num_doc_types;
        for (indexes, 0..) |idx, i| {
            if (done.isSet(i)) continue;
            if (idx == documents[i].len)
                done.set(i)
            else
                keys[i] = documents[i][idx].date.?.sortKey();
        }
        if (done.count() == num_doc_types) break;
        const i = std.mem.findMax(u64, &keys);
        try result.append(allocator, values[i][indexes[i]]);
        indexes[i] += 1;
    }
    return result.items;
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
    allocator: Allocator,
    io: std.Io,
    templates: std.StringHashMapUnmanaged(Value),
    scope: Scope,

    pub fn writeUrl(self: MarkdownHooks, writer: *std.Io.Writer, context: Markdown.HookContext, url: []const u8) !void {
        return writeUrlOrImage(self, writer, context, url, false, null);
    }

    pub fn writeImage(self: MarkdownHooks, writer: *std.Io.Writer, context: Markdown.HookContext, url: []const u8, info: ?Markdown.ImageInfo) !void {
        return writeUrlOrImage(self, writer, context, url, true, info);
    }

    fn writeUrlOrImage(self: MarkdownHooks, writer: *std.Io.Writer, context: Markdown.HookContext, url: []const u8, is_image: bool, info: ?Markdown.ImageInfo) !void {
        const options_ptr: ?*const HookOptions = @ptrCast(context.options.hook_options);
        const options = if (options_ptr) |ptr| ptr.* else HookOptions{};
        if (url.len == 0) return context.fail("{s}: unexpected empty URL", .{url});
        if (url[0] == '/') return writeNonSvg(writer, is_image, info, options.absolute_urls, "{s}", .{url});
        const has_protocol = mem.find(u8, url, "://") != null;
        const hash_idx = mem.findScalar(u8, url, '#') orelse url.len;
        if (has_protocol or hash_idx == 0) return writeNonSvg(writer, is_image, info, false, "{s}", .{url});
        const fragment = url[hash_idx..];
        var path_buffer: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&path_buffer);
        const path = try std.fs.path.resolve(fba.allocator(), &.{ context.filename, "..", url[0..hash_idx] });
        std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| return context.fail("{s}: {t}", .{ url, err });
        const final_url = urlFromPath(path) orelse return context.fail("{s}: path is outside website", .{url});
        if (is_image and mem.endsWith(u8, path, ".svg")) {
            const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var reader = file.reader(self.io, &buffer);
            _ = try writer.sendFileAll(&reader, .unlimited);
            return;
        }
        return writeNonSvg(writer, is_image, info, options.absolute_urls, "{s}{s}", .{ final_url, fragment });
    }

    fn writeNonSvg(writer: *std.Io.Writer, is_image: bool, info: ?Markdown.ImageInfo, make_absolute: bool, comptime format: []const u8, args: anytype) !void {
        if (is_image) try writer.writeAll("<img src=\"");
        if (make_absolute) try writer.writeAll(constants.site_url);
        try writer.print(format, args);
        if (is_image) {
            try writer.writeByte('"');
            if (info) |i| {
                try writer.print(" width=\"{s}\" height=\"{s}\"", .{ i.width, i.height });
                if (i.lazy) try writer.writeAll(" loading=\"lazy\"");
            }
            try writer.writeByte('>');
        }
    }

    pub fn renderTemplate(self: MarkdownHooks, writer: *std.Io.Writer, context: Markdown.HookContext, name: []const u8) anyerror!void {
        const template = try getTemplate(context.reporter, self.templates, name);
        try template.execute(self.allocator, context.reporter, writer, self, self.scope);
    }

    pub fn parseAndRenderTemplate(self: MarkdownHooks, writer: *std.Io.Writer, context: Markdown.HookContext, scanner: *Scanner) anyerror!void {
        const template = try Template.parse(self.allocator, scanner);
        try template.execute(self.allocator, context.reporter, writer, self, self.scope);
    }
};

fn sectionFromPath(path: []const u8) ?[]const u8 {
    const prefix = constants.src_site_dir ++ "/";
    if (!mem.startsWith(u8, path, prefix)) return null;
    const public_rel_path = path[prefix.len..];
    if (mem.findScalar(u8, public_rel_path, '/')) |index| return public_rel_path[0..index];
    if (mem.findScalar(u8, public_rel_path, '.')) |index| return public_rel_path[0..index];
    return null;
}

fn urlFromPath(path: []const u8) ?[]const u8 {
    const no_ext = removeSuffixes(path, &.{ ".md", ".html", ".php", ".phtml", ".rss" });
    const no_index = removeSuffixes(no_ext, &.{"/index"});
    const prefix = constants.src_site_dir;
    return if (std.mem.startsWith(u8, no_index, prefix)) no_index[prefix.len..] else null;
}

fn getFeedUrl(opt_url: ?[]const u8, opt_section: ?[]const u8) ?[]const u8 {
    const url = opt_url orelse return null;
    if (url.len == 0) return "/feed";
    const section = opt_section orelse return null;
    if (mem.eql(u8, section, "blog")) return "/blog/feed";
    if (mem.eql(u8, section, "crafts")) return "/crafts/feed";
    if (mem.eql(u8, section, "books")) return "/books/feed";
    if (mem.eql(u8, section, "recipes")) return "/recipes/feed";
    return null;
}

fn removeSuffixes(string: []const u8, suffixes: []const []const u8) []const u8 {
    for (suffixes) |suffix| if (std.mem.endsWith(u8, string, suffix)) return string[0 .. string.len - suffix.len];
    return string;
}

fn changeExtension(allocator: Allocator, path: []const u8, new_ext: []const u8) ![]const u8 {
    const index = mem.findScalarLast(u8, path, '.') orelse return path;
    return mem.concat(allocator, u8, &.{ path[0..index], new_ext });
}
