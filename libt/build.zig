const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("libt", .{
        .source_file = .{ .path = "libt.zig" },
    });
}
