const libt = @import("libt.zig");
const syscall = libt.syscall;
const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const page_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &PageAllocator.vtable,
};

const PageAllocator = struct {
    pub const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = &Allocator.noResize,
        .free = free,
    };

    fn alloc(_: *anyopaque, n: usize, _: u8, _: usize) ?[*]u8 {
        const pages = math.divCeil(usize, n, mem.page_size) catch unreachable;
        const region = syscall.regionAllocate(.self, pages, .{ .read = true, .write = true }, null) catch return null;
        const result = syscall.regionMap(.self, region, null) catch {
            syscall.regionFree(.self, region) catch unreachable;
            return null;
        };
        return @ptrCast(result);
    }

    fn free(_: *anyopaque, slice: []u8, _: u8, _: usize) void {
        const region = syscall.regionUnmap(.self, @alignCast(@ptrCast(slice.ptr))) catch unreachable;
        syscall.regionFree(.self, region) catch unreachable;
    }
};
