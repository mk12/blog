// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module provides a bounded stack for keeping track of markup tags.
//! The Tag type must implement the following methods:
//!
//!     fn writeOpenTag(self: Tag, writer: *std.Io.Writer) !void
//!     fn writeCloseTag(self: Tag, writer: *std.Io.Writer) !void
//!
//! These are used to write tags when you push/pop the stack.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub const max_depth = 8;

pub fn TagStack(comptime Tag: type) type {
    return struct {
        const TagNoPayload = if (@typeInfo(Tag) == .@"union") std.meta.Tag(Tag) else Tag;
        items: [max_depth]Tag = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const Tag {
            return self.items[0..self.len];
        }

        pub fn get(self: @This(), i: usize) Tag {
            return self.items[i];
        }

        pub fn getPtr(self: *@This(), i: usize) *Tag {
            return &self.items[i];
        }

        pub fn top(self: @This()) ?Tag {
            return if (self.len == 0) null else self.items[self.len - 1];
        }

        pub fn push(self: *@This(), writer: *std.Io.Writer, item: Tag) !void {
            try item.writeOpenTag(writer);
            try self.pushWithoutWriting(item);
        }

        pub fn pushWithoutWriting(self: *@This(), item: Tag) !void {
            if (self.len == self.items.len) return error.ExceededMaxTagDepth;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn append(self: *@This(), writer: *std.Io.Writer, items: []const Tag) !void {
            for (items) |item| try self.push(writer, item);
        }

        pub fn pop(self: *@This(), writer: *std.Io.Writer) !void {
            self.len -= 1;
            try self.items[self.len].writeCloseTag(writer);
        }

        pub fn popTag(self: *@This(), writer: *std.Io.Writer, tag: TagNoPayload) !void {
            assert(self.top().? == tag);
            try self.pop(writer);
        }

        pub fn toggle(self: *@This(), writer: *std.Io.Writer, item: Tag) !void {
            try if (self.top() == item) self.pop(writer) else self.push(writer, item);
        }

        pub fn truncate(self: *@This(), writer: *std.Io.Writer, new_len: usize) !void {
            while (self.len > new_len) try self.pop(writer);
        }
    };
}

const TestTag = enum {
    foo,
    bar,

    fn writeOpenTag(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("<{t}>", .{self});
    }

    fn writeCloseTag(self: @This(), writer: *std.Io.Writer) !void {
        try writer.print("</{t}>", .{self});
    }
};

test "empty stack" {
    const stack = TagStack(TestTag){};
    try testing.expectEqual(@as(usize, 0), stack.len);
    try testing.expectEqual(@as(?TestTag, null), stack.top());
}

test "basic operations" {
    var stack = TagStack(TestTag){};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stack.push(&output.writer, .foo);
    try testing.expectEqual(@as(usize, 1), stack.len);
    try testing.expectEqual(@as(?TestTag, TestTag.foo), stack.top());
    try stack.push(&output.writer, .bar);
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expectEqual(TestTag.foo, stack.get(0));
    try testing.expectEqual(TestTag.bar, stack.get(1));
    try testing.expectEqual(@as(?TestTag, TestTag.bar), stack.top());
    try stack.pop(&output.writer);
    try testing.expectEqual(@as(usize, 1), stack.len);
    try testing.expectEqual(@as(?TestTag, TestTag.foo), stack.top());
    try stack.pop(&output.writer);
    try testing.expectEqual(@as(usize, 0), stack.len);
    try testing.expectEqualStrings("<foo><bar></bar></foo>", output.written());
}

test "pushWithoutWriting" {
    var stack = TagStack(TestTag){};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stack.pushWithoutWriting(.foo);
    try stack.pop(&output.writer);
    try testing.expectEqualStrings("</foo>", output.written());
}

test "append" {
    var stack = TagStack(TestTag){};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stack.append(&output.writer, &.{ .foo, .bar });
    try testing.expectEqualStrings("<foo><bar>", output.written());
}

test "popTag" {
    var stack = TagStack(TestTag){};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stack.push(&output.writer, .foo);
    try stack.popTag(&output.writer, .foo);
}

test "toggle" {
    var stack = TagStack(TestTag){};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stack.toggle(&output.writer, .foo);
    try stack.toggle(&output.writer, .bar);
    try stack.toggle(&output.writer, .foo);
    try stack.toggle(&output.writer, .foo);
    try stack.toggle(&output.writer, .bar);
    try stack.toggle(&output.writer, .foo);
    try testing.expectEqualStrings("<foo><bar><foo></foo></bar></foo>", output.written());
}

test "truncate" {
    var stack = TagStack(TestTag){};
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try stack.append(&output.writer, &.{ .foo, .bar, .foo });
    try stack.truncate(&output.writer, 1);
    try testing.expectEqualStrings("<foo><bar><foo></foo></bar>", output.written());
}
