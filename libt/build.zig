const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_entry_point = b.option(bool, "include_entry_point", "") orelse false;
    const stack_size = b.option(u32, "stack_size", "") orelse 0x10;
    const options = b.addOptions();
    options.addOption(bool, "include_entry_point", include_entry_point);
    options.addOption(usize, "stack_size", stack_size);

    const module = b.addModule("libt", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("libt.zig"),
    });
    module.addOptions("options", options);
}
