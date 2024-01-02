const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const target = CrossTarget{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none };
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "init.elf",
        .target = target,
        .optimize = optimize,
    });
    exe.addAssemblyFile(.{ .path = "main.s" });
    b.installArtifact(exe);
}
