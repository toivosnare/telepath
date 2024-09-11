const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub const service = @import("service.zig");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_entry_point = b.option(bool, "include_entry_point", "") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "include_entry_point", include_entry_point);

    const module = b.addModule("libt", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("libt.zig"),
    });
    module.addOptions("options", options);
}

pub fn addTelepathExecutable(
    b: *Build,
    executable_options: Build.ExecutableOptions,
    service_options: []const service.Options,
) *Step.Compile {
    const dependency = b.dependency("libt", .{
        .target = executable_options.target,
        .optimize = executable_options.optimize,
        .include_entry_point = true,
    });

    const exe = b.addExecutable(executable_options);
    const module = dependency.module("libt");
    exe.root_module.addImport("libt", module);
    service.add(exe, service_options, module);
    return exe;
}
