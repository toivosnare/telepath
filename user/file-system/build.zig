const std = @import("std");
const libt = @import("libt");
const service = libt.service;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const exe = libt.addTelepathExecutable(b, .{
        .name = "file-system",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }, &[_]libt.ServiceOptions{
        .{ .name = "serial", .service = service.serial_driver },
        .{ .name = "rtc", .service = service.rtc_driver },
        .{ .name = "block", .service = service.block_driver },
        .{ .name = "client", .service = service.directory, .mode = .provide },
    });

    b.installArtifact(exe);
}
