const std = @import("std");

pub fn build(b: *std.Build) void {
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
