const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const kernel_package = b.dependency("kernel", .{
        .optimize = optimize,
    });
    const kernel = kernel_package.artifact("kernel");
    b.installArtifact(kernel);

    const init_package = b.dependency("init", .{
        .optimize = optimize,
    });
    const init = init_package.artifact("init.elf");
    b.installArtifact(init);

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
