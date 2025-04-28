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

    const exe = libt.addTelepathExecutable(b, "goldfish-rtc", b.path("main.zig"), target, optimize, &[_]libt.ServiceOptions{
        .{ .name = "serial", .service = service.SerialDriver },
        .{ .name = "client", .service = service.RtcDriver, .mode = .provide },
    });
    exe.root_module.addImport("datetime", @"zig-datetime".module("datetime"));

    b.installArtifact(exe);
}
