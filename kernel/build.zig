const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const @"dtb.zig" = b.dependency("dtb.zig", .{});
    const libt = b.dependency("libt", .{});
    const @"zig-sbi" = b.dependency("zig-sbi", .{});

    const entry = @import("entry.zig");
    const entry_header = b.addConfigHeader(.{
        .include_path = "entry.h",
    }, .{
        .KERNEL_STACK_SIZE_PER_HART = entry.kernel_stack_size_per_hart,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .code_model = .medium,
        .strip = false,
    });
    kernel.addAssemblyFile(b.path("entry.S"));
    kernel.setLinkerScript(b.path("kernel.ld"));
    kernel.addIncludePath(entry_header.getOutput().dirname());
    kernel.root_module.addImport("dtb", @"dtb.zig".module("dtb"));
    kernel.root_module.addImport("libt", libt.module("libt"));
    kernel.root_module.addImport("sbi", @"zig-sbi".module("sbi"));
    kernel.entry = .{ .symbol_name = "bootHartEntry" };
    kernel.step.dependOn(&entry_header.step);
    b.installArtifact(kernel);
}
