// Copyright 2023 Mitchell Kember. Subject to the MIT License.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "list-posts",
        .root_source_file = .{ .path = "list-posts.zig" },
        .target = b.standardTargetOptions(.{}),
        // TODO: Configure this.
        .optimize = .ReleaseSmall,
        .single_threaded = true,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);
}
