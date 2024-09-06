const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const libt = b.dependency("libt", .{
        .target = target,
        .optimize = optimize,
        .include_entry_point = true,
    });

    const exe = b.addExecutable(.{
        .name = "ns16550a",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("libt", libt.module("libt"));
    b.installArtifact(exe);
}
