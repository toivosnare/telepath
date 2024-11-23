const std = @import("std");
const libt = @import("libt");
const service = libt.service;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const exe = libt.addTelepathExecutable(b, .{
        .name = "virtio-blk",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }, &[_]libt.ServiceOptions{
        .{ .name = "stdout", .service = service.byte_stream },
        .{ .name = "client", .service = service.disk_driver, .mode = .provide },
    });

    b.installArtifact(exe);
}
