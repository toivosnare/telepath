const std = @import("std");
const libt = @import("libt");
const service = libt.service;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const exe = libt.addTelepathExecutable(b, "virtio-blk", b.path("main.zig"), target, optimize, &[_]libt.ServiceOptions{
        .{ .name = "serial", .service = service.SerialDriver },
        .{ .name = "client", .service = service.BlockDriver, .mode = .provide },
    });

    b.installArtifact(exe);
}
