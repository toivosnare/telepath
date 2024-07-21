const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const @"dtb.zig" = b.dependency("dtb.zig", .{});
    const libt = b.dependency("libt", .{});
    const @"zig-sbi" = b.dependency("zig-sbi", .{});

    const mm = @import("src/mm.zig");
    const entry_defines = b.addConfigHeader(.{
        .include_path = "entry_defines.h",
    }, .{
        .KERNEL_STACK_SIZE_PER_HART = mm.KERNEL_STACK_SIZE_PER_HART,
        .KERNEL_STACK_SIZE_TOTAL = mm.KERNEL_STACK_SIZE_TOTAL,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .code_model = .medium,
        .strip = false,
    });
    kernel.addAssemblyFile(b.path("src/entry.S"));
    kernel.setLinkerScript(b.path("src/kernel.ld"));
    kernel.addIncludePath(entry_defines.getOutput().dirname());
    kernel.root_module.addImport("dtb", @"dtb.zig".module("dtb"));
    kernel.root_module.addImport("libt", libt.module("libt"));
    kernel.root_module.addImport("sbi", @"zig-sbi".module("sbi"));
    kernel.entry = .{ .symbol_name = "bootHartEntry" };
    kernel.step.dependOn(&entry_defines.step);
    b.installArtifact(kernel);
}
