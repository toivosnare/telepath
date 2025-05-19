const std = @import("std");
const libt = @import("libt");
const service = libt.service;
const interface = @import("interface.zig");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .freestanding, .abi = .none });
    const optimize = b.standardOptimizeOption(.{});

    const client = libt.addTelepathExecutable(b, "benchmark-client", b.path("client.zig"), target, optimize, &[_]libt.ServiceOptions{
        .{ .name = "control", .service = interface.Control, .mode = .consume },
        .{ .name = "serial", .service = service.SerialDriver },
    });
    b.installArtifact(client);

    const server = libt.addTelepathExecutable(b, "benchmark-server", b.path("server.zig"), target, optimize, &[_]libt.ServiceOptions{
        .{ .name = "control", .service = interface.Control, .mode = .provide },
    });
    b.installArtifact(server);
}
