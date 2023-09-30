// Copyright 2023 Mitchell Kember. Subject to the MIT License.

//! This module provides a bounded stack for keeping track of markup tags.
//! The Tag type must implement the following methods:
//!
//!     fn writeOpenTag(self: Tag, writer: anytype) !void
//!     fn writeCloseTag(self: Tag, writer: anytype) !void
//!
//! These are used to write tags when you push/pop the stack.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

pub const max_depth = 8;

pub fn TagStack(comptime Tag: type) type {
    return struct {
        const Self = @This();
        const TagNoPayload = if (@typeInfo(Tag) == .Union) std.meta.Tag(Tag) else Tag;
        items: std.BoundedArray(Tag, max_depth) = .{},

        pub fn len(self: Self) usize {
            return self.items.len;
        }

        pub fn get(self: Self, i: usize) Tag {
            return self.items.get(i);
        }

        pub fn getPtr(self: *Self, i: usize) *Tag {
            return &self.items.slice()[i];
        }

        pub fn top(self: Self) ?Tag {
            return if (self.len() == 0) null else self.items.get(self.len() - 1);
        }

        pub fn push(self: *Self, writer: anytype, item: Tag) !void {
            try item.writeOpenTag(writer);
            try self.pushWithoutWriting(item);
        }

        pub fn pushWithoutWriting(self: *Self, item: Tag) !void {
            self.items.append(item) catch |err| return switch (err) {
                error.Overflow => error.ExceededMaxTagDepth,
            };
        }

        pub fn append(self: *Self, writer: anytype, items: anytype) !void {
            inline for (items) |item| try self.push(writer, item);
        }

        pub fn pop(self: *Self, writer: anytype) !void {
            try self.items.pop().writeCloseTag(writer);
        }

        pub fn popWithoutWriting(self: *Self) void {
            _ = self.items.pop();
        }

        pub fn popTag(self: *Self, writer: anytype, tag: TagNoPayload) !void {
            assert(self.top().? == tag);
            try self.pop(writer);
        }

        pub fn toggle(self: *Self, writer: anytype, item: Tag) !void {
            try if (self.top() == item) self.pop(writer) else self.push(writer, item);
        }

        pub fn truncate(self: *Self, writer: anytype, new_len: usize) !void {
            while (self.items.len > new_len) try self.pop(writer);
        }
    };
}

const TestTag = enum {
    foo,
    bar,

    fn writeOpenTag(self: @This(), writer: anytype) !void {
        try std.fmt.format(writer, "<{s}>", .{@tagName(self)});
    }

    fn writeCloseTag(self: @This(), writer: anytype) !void {
        try std.fmt.format(writer, "</{s}>", .{@tagName(self)});
    }
};

test "empty stack" {
    const stack = TagStack(TestTag){};
    try testing.expectEqual(@as(usize, 0), stack.len());
    try testing.expectEqual(@as(?TestTag, null), stack.top());
}

test "basic operations" {
    var stack = TagStack(TestTag){};
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try stack.push(output.writer(), .foo);
    try testing.expectEqual(@as(usize, 1), stack.len());
    try testing.expectEqual(@as(?TestTag, TestTag.foo), stack.top());
    try stack.push(output.writer(), .bar);
    try testing.expectEqual(@as(usize, 2), stack.len());
    try testing.expectEqual(TestTag.foo, stack.get(0));
    try testing.expectEqual(TestTag.bar, stack.get(1));
    try testing.expectEqual(@as(?TestTag, TestTag.bar), stack.top());
    try stack.pop(output.writer());
    try testing.expectEqual(@as(usize, 1), stack.len());
    try testing.expectEqual(@as(?TestTag, TestTag.foo), stack.top());
    try stack.pop(output.writer());
    try testing.expectEqual(@as(usize, 0), stack.len());
    try testing.expectEqualStrings("<foo><bar></bar></foo>", output.items);
}

test "pushWithoutWriting" {
    var stack = TagStack(TestTag){};
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try stack.pushWithoutWriting(.foo);
    try stack.pop(output.writer());
    try testing.expectEqualStrings("</foo>", output.items);
}

test "popWithoutWriting" {
    var stack = TagStack(TestTag){};
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try stack.push(output.writer(), .foo);
    stack.popWithoutWriting();
    try testing.expectEqualStrings("<foo>", output.items);
}

test "append" {
    var stack = TagStack(TestTag){};
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try stack.append(output.writer(), .{ .foo, .bar });
    try testing.expectEqualStrings("<foo><bar>", output.items);
}

test "popTag" {
    var stack = TagStack(TestTag){};
    try stack.push(std.io.null_writer, .foo);
    try stack.popTag(std.io.null_writer, .foo);
}

test "toggle" {
    var stack = TagStack(TestTag){};
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try stack.toggle(output.writer(), .foo);
    try stack.toggle(output.writer(), .bar);
    try stack.toggle(output.writer(), .foo);
    try stack.toggle(output.writer(), .foo);
    try stack.toggle(output.writer(), .bar);
    try stack.toggle(output.writer(), .foo);
    try testing.expectEqualStrings("<foo><bar><foo></foo></bar></foo>", output.items);
}

test "truncate" {
    var stack = TagStack(TestTag){};
    var output = std.ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    try stack.append(output.writer(), .{ .foo, .bar, .foo });
    try stack.truncate(output.writer(), 1);
    try testing.expectEqualStrings("<foo><bar><foo></foo></bar>", output.items);
}
