const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libt = b.dependency("libt", .{});

    const exe = b.addExecutable(.{
        .name = "elf2tix",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("libt", libt.module("libt"));
    b.installArtifact(exe);
}
