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
        const region = syscall.allocate(pages, .{ .readable = true, .writable = true }, null) catch return null;
        const result = syscall.map(region, null) catch {
            syscall.free(region) catch unreachable;
            return null;
        };
        return @ptrCast(result);
    }

    fn free(_: *anyopaque, slice: []u8, _: u8, _: usize) void {
        const region = syscall.unmap(@alignCast(@ptrCast(slice.ptr))) catch unreachable;
        syscall.free(region) catch unreachable;
    }
};
