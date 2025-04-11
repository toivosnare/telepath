const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const libt = b.dependency("libt", .{
        .target = target,
        .optimize = optimize,
    });
    const ns16550a = b.dependency("ns16550a", .{ .optimize = optimize });
    const @"goldfish-rtc" = b.dependency("goldfish-rtc", .{ .optimize = optimize });
    const @"virtio-blk" = b.dependency("virtio-blk", .{ .optimize = optimize });
    const @"file-system" = b.dependency("file-system", .{ .optimize = optimize });
    const shell = b.dependency("shell", .{ .optimize = optimize });

    const drivers = [_]*Step.Compile{
        ns16550a.artifact("ns16550a"),
        @"goldfish-rtc".artifact("goldfish-rtc"),
        @"virtio-blk".artifact("virtio-blk"),
        @"file-system".artifact("file-system"),
        shell.artifact("shell"),
    };
    for (drivers) |driver| {
        b.installArtifact(driver);
    }

    const tar = b.addSystemCommand(&[_][]const u8{ "tar", "--transform=s/.*\\///", "-cPf" });
    const driver_archive = tar.addOutputFileArg("driver_archive.tar");
    for (drivers) |driver|
        tar.addFileArg(driver.getEmittedBin());
    const install_driver_archive = b.addInstallFile(driver_archive, "driver_archive.tar");
    b.getInstallStep().dependOn(&install_driver_archive.step);

    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "init.elf",
        .root_module = module,
    });
    exe.root_module.addImport("libt", libt.module("libt"));
    exe.root_module.addAnonymousImport("driver_archive.tar", .{
        .root_source_file = driver_archive,
    });
    b.installArtifact(exe);
}
