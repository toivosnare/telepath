const std = @import("std");
const math = std.math;
const mem = std.mem;
const heap = std.heap;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const libt = @import("root.zig");
const syscall = libt.syscall;

pub const page_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &PageAllocator.vtable,
};

const PageAllocator = struct {
    pub const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = &Allocator.noResize,
        .remap = &Allocator.noRemap,
        .free = free,
    };

    fn alloc(_: *anyopaque, n: usize, alignment: mem.Alignment, _: usize) ?[*]u8 {
        const page_size = heap.pageSize();
        assert(alignment.compare(.gte, .fromByteUnits(page_size)));

        const page_count = math.divCeil(usize, n, page_size) catch unreachable;
        const region = syscall.regionAllocate(.self, page_count, .{ .read = true, .write = true }, null) catch return null;

        var candidate_address = @intFromPtr(syscall.regionMap(.self, region, null) catch {
            @branchHint(.unlikely);
            syscall.regionFree(.self, region) catch unreachable;
            return null;
        });

        if (alignment.check(candidate_address))
            return @ptrFromInt(candidate_address);

        _ = syscall.regionUnmap(.self, @ptrFromInt(candidate_address)) catch unreachable;
        const alignment_bytes = alignment.toByteUnits();
        candidate_address = mem.alignForward(usize, candidate_address, alignment_bytes);

        while (candidate_address + n <= libt.address_space_end) {
            @branchHint(.likely);

            if (syscall.regionMap(.self, region, @ptrFromInt(candidate_address))) |_| {
                return @ptrFromInt(candidate_address);
            } else |err| switch (err) {
                error.Reserved => candidate_address += alignment_bytes,
                else => unreachable,
            }
        }

        syscall.regionFree(.self, region) catch unreachable;
        return null;
    }

    fn free(_: *anyopaque, slice: []u8, _: mem.Alignment, _: usize) void {
        const region = syscall.regionUnmap(.self, @alignCast(@ptrCast(slice.ptr))) catch unreachable;
        syscall.regionFree(.self, region) catch unreachable;
    }
};
