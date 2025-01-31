const std = @import("std");
const libt = @import("libt");
const service = libt.service;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const exe = libt.addTelepathExecutable(b, .{
        .name = "shell",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }, &[_]libt.ServiceOptions{
        .{ .name = "serial_driver", .service = service.SerialDriver },
        .{ .name = "block_driver", .service = service.BlockDriver },
        .{ .name = "root_directory", .service = service.Directory },
        .{ .name = "rtc_driver", .service = service.RtcDriver },
    });

    b.installArtifact(exe);
}
