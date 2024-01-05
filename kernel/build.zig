const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const target = CrossTarget{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none };
    const optimize = b.standardOptimizeOption(.{});

    const @"dtb.zig" = b.dependency("dtb.zig", .{});
    const libt = b.dependency("libt", .{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    kernel.addAssemblyFile(.{ .path = "src/entry.s" });
    kernel.setLinkerScript(.{ .path = "src/kernel.ld" });
    kernel.addModule("dtb", @"dtb.zig".module("dtb"));
    kernel.addModule("libt", libt.module("libt"));
    kernel.code_model = .medium;
    kernel.strip = false;
    b.installArtifact(kernel);
}
