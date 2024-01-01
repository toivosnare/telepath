const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const target = CrossTarget{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none };
    const optimize = b.standardOptimizeOption(.{});

    const @"dtb.zig" = b.dependency("dtb.zig", .{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    kernel.addAssemblyFile(.{ .path = "src/entry.s" });
    kernel.setLinkerScript(.{ .path = "src/kernel.ld" });
    kernel.addModule("dtb", @"dtb.zig".module("dtb"));
    kernel.code_model = .medium;
    kernel.strip = false;
    b.installArtifact(kernel);

    const QEMU_ARGV = [_][]const u8{
        "qemu-system-riscv64",
        "-machine",
        "virt",
        "-bios",
        "default",
        "-serial",
        "mon:stdio",
        "-nographic",
        "-kernel",
    };

    const run_cmd = b.addSystemCommand(&QEMU_ARGV);
    run_cmd.addFileArg(kernel.getEmittedBin());
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const debug_cmd = b.addSystemCommand(&QEMU_ARGV);
    debug_cmd.addFileArg(kernel.getEmittedBin());
    debug_cmd.addArgs(&[_][]const u8{ "-S", "-s" });
    debug_cmd.step.dependOn(b.getInstallStep());

    const debug_step = b.step("debug", "Debug the app");
    debug_step.dependOn(&debug_cmd.step);
}
