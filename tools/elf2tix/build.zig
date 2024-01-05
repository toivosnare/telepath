const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libt = b.dependency("libt", .{});

    const exe = b.addExecutable(.{
        .name = "elf2tix",
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("libt", libt.module("libt"));
    b.installArtifact(exe);
}
