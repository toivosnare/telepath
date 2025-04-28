const std = @import("std");
const libt = @import("libt");
const service = libt.service;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const exe = libt.addTelepathExecutable(b, "file-system", b.path("main.zig"), target, optimize, &[_]libt.ServiceOptions{
        .{ .name = "serial", .service = service.SerialDriver },
        .{ .name = "rtc", .service = service.RtcDriver },
        .{ .name = "block", .service = service.BlockDriver },
        .{ .name = "root_directory_region", .service = service.Directory, .mode = .provide },
    });

    b.installArtifact(exe);
}
