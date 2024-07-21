const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "init.elf",
        .target = target,
        .optimize = optimize,
    });
    exe.addAssemblyFile(b.path("main.s"));
    b.installArtifact(exe);
}
