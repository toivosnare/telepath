const std = @import("std");
const log = std.log;
const mem = std.mem;
const assert = std.debug.assert;

pub const Region = @import("mm/Region.zig");
pub const page_allocator = @import("mm/page_allocator.zig");

pub const PAGE_SIZE = std.mem.page_size;
pub const Address = usize;
pub const VirtualAddress = Address;
pub const PhysicalAddress = Address;

pub const Page = [PAGE_SIZE]u8;
pub const PagePtr = *align(PAGE_SIZE) Page;
pub const ConstPagePtr = *align(PAGE_SIZE) const Page;
pub const PageSlice = []align(PAGE_SIZE) Page;
pub const ConstPageSlice = []align(PAGE_SIZE) const Page;

pub const PageFrame = Page;
pub const PageFramePtr = PagePtr;
pub const ConstPageFramePtr = ConstPagePtr;
pub const PageFrameSlice = PageSlice;
pub const ConstPageFrameSlice = ConstPageSlice;

pub const PageTableEntry = packed struct {
    permissions: Permissions,
    accessed: bool,
    dirty: bool,
    _rsw0: u2,
    physical_page_number: PhysicalPageNumber,
    _rsw1: u10,

    pub const Permissions = packed struct {
        valid: bool = false,
        readable: bool = false,
        writable: bool = false,
        executable: bool = false,
        user: bool = false,
        global: bool = false,
    };
    pub const PhysicalPageNumber = packed struct {
        ppn: u44,

        pub fn fromPageTablePtr(ptr: PageTablePtr) PhysicalPageNumber {
            return .{ .ppn = @intCast(@intFromPtr(ptr) >> 12) };
        }

        pub fn fromConstPagePtr(ptr: ConstPagePtr) PhysicalPageNumber {
            return .{ .ppn = @intCast(@intFromPtr(ptr) >> 12) };
        }

        pub fn toPageTablePtr(self: PhysicalPageNumber) PageTablePtr {
            return @ptrFromInt(@as(usize, self.ppn << 12));
        }
    };
};
pub const PageTableEntryPtr = *align(@sizeOf(PageTableEntry)) PageTableEntry;
pub const PageTable = [PAGE_SIZE / @sizeOf(PageTableEntry)]PageTableEntry;
pub const PageTablePtr = *align(PAGE_SIZE) PageTable;

pub fn init(heap: PageFrameSlice, fdt: ConstPageFrameSlice, initrd: ConstPageFrameSlice) void {
    log.info("Initializing memory subsystem.", .{});
    page_allocator.init(heap, fdt, initrd);
    Region.init();
}

pub fn pageFrameOverlapsSlice(ptr: ConstPageFramePtr, slice: ConstPageFrameSlice) bool {
    const ptr_start = @intFromPtr(ptr);
    const ptr_end = ptr_start + @sizeOf(PageFrame);
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len * @sizeOf(PageFrame);
    return ptr_start < slice_end and ptr_end > slice_start;
}
