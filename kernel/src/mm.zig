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

pub var kernel_offset: usize = undefined;

pub fn init(heap: PageFrameSlice, fdt: ConstPageFrameSlice, initrd: ConstPageFrameSlice) void {
    log.info("Initializing memory subsystem.", .{});
    page_allocator.init(heap, fdt, initrd);
    Region.init();
}

pub fn mapKernel(page_table: PageTablePtr, kernel_physical: ConstPageFrameSlice) void {
    const kernel_physical_start = @intFromPtr(kernel_physical.ptr);
    const kernel_virtual_start = kernel_physical_start + 1024 * PAGE_SIZE;
    assert(mem.isAligned(kernel_virtual_start, PAGE_SIZE));
    kernel_offset = kernel_virtual_start - kernel_physical_start;

    var kernel_virtual: ConstPageSlice = undefined;
    kernel_virtual.ptr = @ptrFromInt(kernel_virtual_start);
    kernel_virtual.len = kernel_physical.len;

    mapRange(page_table, kernel_virtual, kernel_physical, .{ .valid = true, .readable = true, .writable = true, .executable = true });
}

pub fn mapRange(page_table: PageTablePtr, virtual: ConstPageSlice, physical: ConstPageFrameSlice, permissions: PageTableEntry.Permissions) void {
    for (virtual, physical) |*v, *p| {
        mapPage(page_table, @alignCast(v), @alignCast(p), permissions);
    }
}

pub fn mapPage(page_table: PageTablePtr, virtual: ConstPagePtr, physical: ConstPageFramePtr, permissions: PageTableEntry.Permissions) void {
    log.debug("{*} -> {*} {}.", .{ virtual.ptr, physical.ptr, permissions });
    var pt = page_table;
    const v = @intFromPtr(virtual);
    var level: usize = 2;
    while (level > 0) : (level -= 1) {
        const index = (v >> @intCast(12 + 9 * level)) & 0b111111111;
        const pte: PageTableEntryPtr = &pt[index];
        if (pte.permissions.valid) {
            pt = pte.physical_page_number.toPageTablePtr();
        } else {
            pt = @ptrCast(page_allocator.allocate() catch @panic("OOM"));
            @memset(mem.asBytes(pt), 0);
            pte.physical_page_number = PageTableEntry.PhysicalPageNumber.fromPageTablePtr(pt);
            pte.permissions = .{ .valid = true };
        }
    }
    const leaf_index = (v >> 12) & 0b111111111;
    const leaf_pte: PageTableEntryPtr = &pt[leaf_index];
    leaf_pte.physical_page_number = PageTableEntry.PhysicalPageNumber.fromConstPagePtr(physical);
    leaf_pte.permissions = permissions;
}

pub fn pageFrameOverlapsSlice(ptr: ConstPageFramePtr, slice: ConstPageFrameSlice) bool {
    const ptr_start = @intFromPtr(ptr);
    const ptr_end = ptr_start + @sizeOf(PageFrame);
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len * @sizeOf(PageFrame);
    return ptr_start < slice_end and ptr_end > slice_start;
}
