const std = @import("std");
const libt = @import("libt");
const service = libt.service;

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const @"zig-datetime" = b.dependency("zig-datetime", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = libt.addTelepathExecutable(b, .{
        .name = "goldfish-rtc",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    }, &[_]libt.ServiceOptions{
        .{ .name = "serial_driver", .service = service.serial_driver },
        .{ .name = "client", .service = service.rtc_driver, .mode = .provide },
    }, 0x6000000);
    exe.root_module.addImport("zig-datetime", @"zig-datetime".module("zig-datetime"));

    b.installArtifact(exe);
}
