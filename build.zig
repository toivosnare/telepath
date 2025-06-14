const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const hart_count = b.option(usize, "hart_count", "Select how many harts to use in QEMU") orelse 2;

    const kernel_package = b.dependency("kernel", .{ .optimize = optimize });
    const kernel = kernel_package.artifact("kernel");
    b.installArtifact(kernel);

    const init_package = b.dependency("init", .{ .optimize = optimize });
    const init_elf = init_package.artifact("init.elf");
    for (init_package.builder.getInstallStep().dependencies.items) |step| {
        const install_step = step.cast(Step.InstallArtifact) orelse continue;
        b.installArtifact(install_step.artifact);
    }

    const elf2tix_package = b.dependency("elf2tix", .{ .optimize = optimize });
    const elf2tix = elf2tix_package.artifact("elf2tix");
    b.installArtifact(elf2tix);

    const elf2tix_cmd = b.addRunArtifact(elf2tix);
    elf2tix_cmd.max_stdio_size *= 2;
    elf2tix_cmd.addFileArg(init_elf.getEmittedBin());
    const init_tix = elf2tix_cmd.captureStdOut();
    const init_tix_install = b.addInstallBinFile(init_tix, "init.tix");
    b.getInstallStep().dependOn(&init_tix_install.step);

    const QEMU_ARGV = [_][]const u8{
        "qemu-system-riscv64",
        "-nographic",
        "-machine",
        "virt",
        "-serial",
        "mon:stdio",
        "-smp",
        b.fmt("{d}", .{hart_count}),
        "-m",
        "2G",
        "-kernel",
    };
    const run_cmd = b.addSystemCommand(&QEMU_ARGV);
    run_cmd.addFileArg(kernel.getEmittedBin());
    run_cmd.addArg("-initrd");
    run_cmd.addFileArg(init_tix);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the OS on QEMU");
    run_step.dependOn(&run_cmd.step);

    const debug_cmd = b.addSystemCommand(&QEMU_ARGV);
    debug_cmd.addFileArg(kernel.getEmittedBin());
    debug_cmd.addArg("-initrd");
    debug_cmd.addFileArg(init_tix);
    debug_cmd.addArgs(&[_][]const u8{ "-S", "-s" });
    debug_cmd.step.dependOn(b.getInstallStep());

    const debug_step = b.step("debug", "Debug the app");
    debug_step.dependOn(&debug_cmd.step);
}
