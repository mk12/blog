// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");

const posts_dir: []const u8 = "posts";
const metadata_separator: []const u8 = "---";
const draft_date: u64 = std.math.maxInt(u64);

const Post = struct {
    date: []const u8,
    json: []const u8,
};

fn descPostDate(context: void, lhs: Post, rhs: Post) bool {
    _ = context;
    return std.mem.order(u8, lhs.date, rhs.date) == .gt;
}

const max_posts: usize = 100;
const scratch_size = max_posts * 256;
var posts_buffer: [max_posts]Post = undefined;
var scratch_buffer: [scratch_size]u8 = undefined;
var output_buffer: [scratch_size]u8 = undefined;
var line_buffer: [1024]u8 = undefined;

pub fn main() !void {
    var posts = std.ArrayListUnmanaged(Post).fromOwnedSlice(&posts_buffer);
    posts.clearRetainingCapacity();
    var scratch = std.io.fixedBufferStream(&scratch_buffer);
    const scratch_writer = scratch.writer();
    const stdout = std.io.getStdOut().writer();

    const destdir = std.os.getenv("DESTDIR") orelse fail("DESTDIR not set", .{});
    const include_drafts = std.mem.eql(u8, destdir, "public");

    var iterable_dir = try std.fs.cwd().openIterableDir(posts_dir, .{});
    defer iterable_dir.close();
    var iter = iterable_dir.iterate();
    file_loop: while (try iter.next()) |entry| {
        const name = entry.name;
        if (name[0] == '.') continue;
        const slug = std.fs.path.stem(name);
        const scratch_start = scratch.pos;
        try std.fmt.format(scratch_writer, "{{\"path\": \"post/{s}/index.html\"", .{slug});
        var file = try iterable_dir.dir.openFile(name, .{});
        defer file.close();
        var buf_reader = std.io.bufferedReaderSize(1024, file.reader());
        var reader = buf_reader.reader();
        const first_line = try reader.readUntilDelimiterOrEof(&line_buffer, '\n');
        if (first_line == null or !std.mem.eql(u8, first_line.?, metadata_separator))
            fail("{s}/{s}: missing '{s}'", .{ posts_dir, name, metadata_separator });
        var date: ?[]const u8 = null;
        while (try reader.readUntilDelimiterOrEof(&line_buffer, '\n')) |line| {
            if (std.mem.eql(u8, line, metadata_separator)) break;
            const idx = std.mem.indexOf(u8, line, ": ") orelse
                fail("{s}/{s}: '{s}': missing colon", .{ posts_dir, name, line });
            const key = line[0..idx];
            const value = line[idx + 2 ..];
            const prev_pos = scratch.pos;
            try std.fmt.format(scratch_writer, ",\"{s}\": \"{s}\"", .{ key, value });
            if (std.mem.eql(u8, key, "date")) {
                if (std.mem.eql(u8, value, "DRAFT")) {
                    if (!include_drafts) continue :file_loop;
                }
                const value_pos = prev_pos + 2 + key.len + 4;
                date = scratch_buffer[value_pos .. value_pos + value.len];
            }
        }
        try scratch_writer.writeAll(",\"summary\": \"");
        const next_line = try reader.readUntilDelimiterOrEof(&line_buffer, '\n');
        if (next_line == null or next_line.?.len != 0)
            fail("{s}/{s}: cannot find summary", .{ posts_dir, name });
        while (try reader.readUntilDelimiterOrEof(&line_buffer, '\n')) |line| {
            if (line.len == 0) break;
            try std.json.encodeJsonStringChars(line, .{}, scratch_writer);
            try scratch_writer.writeAll("\\n");
        }
        try scratch_writer.writeAll("\"}");
        posts.appendAssumeCapacity(.{
            .date = date orelse fail("{s}/{s}: missing date", .{ posts_dir, name }),
            .json = scratch_buffer[scratch_start..scratch.pos],
        });
        try std.fmt.format(stdout, "{s}/post/{s}/index.html\n", .{ destdir, slug });
    }

    std.sort.sort(Post, posts.items, {}, descPostDate);
    var output = std.io.fixedBufferStream(&output_buffer);
    const output_writer = output.writer();
    try output_writer.writeAll("[\n");
    for (0.., posts.items) |i, post| {
        try output_writer.writeAll(post.json);
        if (i != posts.items.len - 1) try output_writer.writeByte(',');
        try output_writer.writeByte('\n');
    }
    try output_writer.writeAll("]\n");

    const posts_path = try std.fmt.bufPrint(&line_buffer, "{s}/.posts.json", .{destdir});
    var posts_file: ?std.fs.File = null;
    if (std.fs.cwd().openFile(posts_path, .{ .mode = .read_write })) |file| {
        const size = try file.readAll(&scratch_buffer);
        if (std.mem.eql(u8, output.getWritten(), scratch_buffer[0..size])) {
            file.close();
        } else {
            try file.setEndPos(0);
            try file.seekTo(0);
            posts_file = file;
        }
    } else |err| {
        _ = err catch {};
        try std.fs.cwd().makePath(destdir);
        posts_file = try std.fs.cwd().createFile(posts_path, .{});
    }
    if (posts_file) |file| {
        defer file.close();
        try file.writeAll(output.getWritten());
    }
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.os.exit(1);
}
