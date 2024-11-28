const std = @import("std");
const log = std.log.scoped(.@"mm.Region");
const math = std.math;
const mm = @import("../mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const Page = mm.Page;
const PageFrameSlice = mm.PageFrameSlice;
const PageSlice = mm.PageSlice;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const Region = @This();

// Ref count of zero implies that the region is not in use.
ref_count: usize,
allocation: PageFrameSlice,
size: usize,
mmio: bool,
lock: Spinlock,

pub const Index = usize;
const max_regions = 128;
var table: [max_regions]Region = undefined;

pub fn init() void {
    for (&table) |*r| {
        r.ref_count = 0;
        r.lock = .{};
    }
}

pub fn allocate(size: usize, physical_address: PhysicalAddress) !*Region {
    log.debug("Allocating Region of size {d}", .{size});
    const region = for (&table) |*r| {
        if (!r.lock.tryLock())
            continue;
        if (r.ref_count == 0)
            break r;
        r.lock.unlock();
    } else {
        log.warn("Could not find free Region table slot", .{});
        return error.OutOfMemory;
    };
    defer region.lock.unlock();
    log.debug("Found free Region index={d}", .{region.index()});

    // FIXME: it is not possible to allocate physical address 0?
    if (physical_address == 0) {
        const order = math.log2_int_ceil(usize, size);
        region.allocation = try mm.page_allocator.allocate(order);
        region.allocation.ptr = mm.physicalFromLogical(region.allocation.ptr);
        region.mmio = false;
    } else {
        if (!std.mem.isAligned(physical_address, @sizeOf(Page))) {
            log.warn("Requested Region physical address (0x{x}) is not aligned to a page boundary", .{physical_address});
            return error.InvalidParameter;
        }
        region.allocation.ptr = @ptrFromInt(physical_address);
        region.allocation.len = size;
        if (mm.pageSlicesOverlap(region.allocation, mm.ram_physical_slice)) {
            log.warn("Requested Region physical address (0x{x}) overlaps with RAM", .{physical_address});
            return error.InvalidParameter;
        }
        region.mmio = true;
    }
    region.ref_count = 1;
    region.size = size;
    return region;
}

pub fn ref(self: *Region) void {
    self.lock.lock();
    self.ref_count += 1;
    log.debug("Adding reference to Region index={d}. Ref count is now {d}", .{ self.index(), self.ref_count });
    self.lock.unlock();
}

pub fn unref(self: *Region) void {
    self.lock.lock();
    self.ref_count -= 1;
    log.debug("Removing reference to Region index={d}. Ref count is now {d}", .{ self.index(), self.ref_count });
    if (self.ref_count == 0 and !self.mmio) {
        log.debug("Freeing allocation of Region index={d}", .{self.index()});
        var logical: PageSlice = undefined;
        logical.ptr = mm.logicalFromPhysical(self.allocation.ptr);
        logical.len = self.allocation.len;
        mm.page_allocator.free(logical);
    }
    self.lock.unlock();
}

pub fn refCount(self: *Region) usize {
    self.lock.lock();
    defer self.lock.unlock();
    return self.ref_count;
}

pub fn isFree(self: *Region) bool {
    return self.refCount() == 0;
}

pub fn sizeInBytes(self: *Region) usize {
    self.lock.lock();
    defer self.lock.unlock();

    return self.size * @sizeOf(Page);
}

pub fn index(self: *const Region) Index {
    // FIXME: use pointer subtraction introduced in Zig 0.14.
    return (@intFromPtr(self) - @intFromPtr(&table[0])) / @sizeOf(Region);
}

pub fn fromIndex(idx: Index) !*Region {
    if (idx >= max_regions)
        return error.InvalidParameter;
    return &table[idx];
}
