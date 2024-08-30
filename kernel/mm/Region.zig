const std = @import("std");
const math = std.math;
const mm = @import("../mm.zig");
const Page = mm.Page;
const PageSlice = mm.PageSlice;
const Region = @This();

// Ref count of zero implies that the region is not in use.
ref_count: usize,
allocation: PageSlice,
size: usize,

pub const Index = usize;
pub const MAX_REGIONS = 128;
pub var table: [MAX_REGIONS]Region = undefined;

pub fn init() void {
    for (&table) |*r| {
        r.ref_count = 0;
    }
}

pub fn findFree() !*Region {
    for (&table) |*r| {
        if (r.isFree())
            return r;
    }
    return error.RegionTableFull;
}

pub fn allocate(size: usize) !*Region {
    const region = try findFree();
    const order = math.log2_int_ceil(usize, size);
    region.allocation = try mm.page_allocator.allocate(order);
    region.ref_count = 1;
    region.size = size;
    return region;
}

pub fn free(self: *Region) void {
    self.ref_count -= 1;
    if (self.ref_count == 0) {
        mm.page_allocator.free(self.allocation);
    }
}

pub fn isFree(self: Region) bool {
    return self.ref_count == 0;
}

pub fn sizeInBytes(self: Region) usize {
    return self.size * @sizeOf(Page);
}
