const std = @import("std");
const log = std.log;
const mem = std.mem;
const assert = std.debug.assert;
const proc = @import("proc.zig");
const entry = @import("entry.zig");

pub const Region = @import("mm/Region.zig");
pub const page_allocator = @import("mm/page_allocator.zig");

pub const Address = usize;
pub const PhysicalAddress = Address;
pub const VirtualAddress = Address;
pub const UserVirtualAddress = VirtualAddress;
pub const LogicalAddress = VirtualAddress;
pub const KernelVirtualAddress = VirtualAddress;

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
    _rsw0: u2 = 0,
    physical_page_number: PhysicalPageNumber,
    _rsw1: u10 = 0,

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

pub const max_user_virtual: UserVirtualAddress = 0x3FFFFFFFFF;
pub const logical_mapping_virtual_start: LogicalAddress = 0xFFFFFFC000000000;
pub const kernel_virtual_start: KernelVirtualAddress = 0xFFFFFFFFFF000000;
pub var logical_mapping_offset: usize = undefined;
pub var kernel_offset: usize = undefined;
pub var address_translation_on: bool = false;

const PAGE_SIZE = std.mem.page_size;
const KERNEL_STACK_SIZE_TOTAL = proc.MAX_HARTS * entry.KERNEL_STACK_SIZE_PER_HART;
export var kernel_stack: [KERNEL_STACK_SIZE_TOTAL]u8 linksection(".bss") = undefined;

pub fn init(heap: PageFrameSlice, holes: []const ConstPageFrameSlice) void {
    log.info("Initializing memory subsystem.", .{});
    page_allocator.init(heap, holes);
    Region.init();
}

pub fn mapRange(page_table: PageTablePtr, virtual: ConstPageSlice, physical: ConstPageFrameSlice, permissions: PageTableEntry.Permissions) void {
    for (virtual, physical) |*v, *p| {
        mapPage(page_table, @alignCast(v), @alignCast(p), permissions);
    }
}

pub fn mapPage(page_table: PageTablePtr, virtual: ConstPagePtr, physical: ConstPageFramePtr, permissions: PageTableEntry.Permissions) void {
    // log.debug("{*} -> {*} {}.", .{ virtual.ptr, physical.ptr, permissions });
    var pt = page_table;
    const v = @intFromPtr(virtual);
    var level: usize = 2;
    while (level > 0) : (level -= 1) {
        const index = (v >> @intCast(12 + 9 * level)) & 0b111111111;
        const pte: PageTableEntryPtr = &pt[index];
        if (pte.permissions.valid) {
            pt = pte.physical_page_number.toPageTablePtr();
        } else {
            pt = @ptrCast(page_allocator.allocate(0) catch @panic("OOM"));
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

pub fn pageSlicesOverlap(a: ConstPageSlice, b: ConstPageSlice) bool {
    const a_start = @intFromPtr(a.ptr);
    const a_end = a_start + a.len * @sizeOf(Page);
    const b_start = @intFromPtr(b.ptr);
    const b_end = b_start + b.len * @sizeOf(Page);
    return a_start < b_end and a_end > b_start;
}

pub fn kernelVirtualFromPhysical(physical: PhysicalAddress) KernelVirtualAddress {
    return physical +% kernel_offset;
}

pub fn physicalFromKernelVirtual(kernel_virtual: KernelVirtualAddress) PhysicalAddress {
    return kernel_virtual -% kernel_offset;
}

pub fn logicalFromPhysical(physical: PhysicalAddress) LogicalAddress {
    return physical +% logical_mapping_offset;
}

pub fn physicalFromLogical(logical: LogicalAddress) PhysicalAddress {
    return logical -% logical_mapping_offset;
}
