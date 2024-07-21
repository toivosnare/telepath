const mm = @import("../mm.zig");
const PagePtr = mm.PagePtr;
const PageSlice = mm.PageSlice;
const Region = @This();

// Ref count of zero implies that the region is not in use.
ref_count: usize,
pages: PageSlice,

const MAX_REGIONS = 128;
var regions: [MAX_REGIONS]Region = undefined;

pub fn init() void {
    for (&regions) |*r| {
        r.ref_count = 0;
    }
}

pub fn allocate(order: usize) !*Region {
    for (&regions) |*r| {
        if (r.isFree()) {
            r.pages = try mm.page_allocator.allocate(order);
            r.ref_count = 1;
            return r;
        }
    }
    return error.RegionTableFull;
}

pub fn free(self: *Region) void {
    mm.page_allocator.free(self.pages);
    self.ref_count = 0;
}

pub fn isFree(self: Region) bool {
    return self.ref_count == 0;
}
