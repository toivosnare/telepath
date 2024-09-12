const std = @import("std");
const log = std.log;
const mem = std.mem;
const assert = std.debug.assert;
const libt = @import("libt");
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

pub const Page = [mem.page_size]u8;
pub const PagePtr = *align(@sizeOf(Page)) Page;
pub const ConstPagePtr = *align(@sizeOf(Page)) const Page;
pub const PageSlice = []align(@sizeOf(Page)) Page;
pub const ConstPageSlice = []align(@sizeOf(Page)) const Page;
pub const PageFrame = Page;
pub const PageFramePtr = PagePtr;
pub const ConstPageFramePtr = ConstPagePtr;
pub const PageFrameSlice = PageSlice;
pub const ConstPageFrameSlice = ConstPageSlice;

pub const PageTable = struct {
    entries: [entry_count]Entry,

    pub const Entry = packed struct(u64) {
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
    };
    pub const entry_count = @sizeOf(Page) / @sizeOf(Entry);
    pub const Level = u4;
    pub const Index = u9;
    pub const Ptr = *align(@sizeOf(Page)) PageTable;

    pub fn mapRange(self: Ptr, virtual: ConstPageSlice, physical: ConstPageFrameSlice, permissions: Entry.Permissions) !void {
        errdefer self.unmapRange(virtual);
        for (virtual, physical) |*v, *p|
            try self.map(v, p, permissions);
    }

    pub fn map(self: Ptr, virtual: ConstPagePtr, physical: ConstPageFramePtr, permissions: Entry.Permissions) !void {
        const pte: *Entry = try self.walk(virtual, true);
        pte.physical_page_number = PhysicalPageNumber.fromPageFrame(physical);
        pte.permissions = permissions;
    }

    pub fn unmapRange(self: Ptr, virtual: ConstPageSlice) void {
        for (virtual) |*v|
            self.unmap(v);
    }

    pub fn unmap(self: Ptr, virtual: ConstPagePtr) void {
        const pte: *Entry = self.walk(virtual, false) catch return;
        pte.permissions = .{};
    }

    pub fn translate(self: Ptr, virtual: VirtualAddress) !PhysicalAddress {
        const page: ConstPagePtr = @ptrFromInt(mem.alignBackward(VirtualAddress, virtual, @sizeOf(Page)));
        const pte = try self.walk(page, false);
        const page_frame = pte.physical_page_number.toPageFrame();
        const page_offset = virtual % @sizeOf(Page);
        return @intFromPtr(page_frame) + page_offset;
    }

    pub fn walk(self: Ptr, virtual: ConstPagePtr, allocate: bool) !*Entry {
        var page_table: Ptr = self;
        var level: Level = 2;
        while (level > 0) : (level -= 1) {
            const pte_index = PageTable.index(virtual, level);
            const pte: *Entry = &page_table.entries[pte_index];
            if (pte.permissions.valid) {
                page_table = pte.physical_page_number.toPageTable();
            } else if (allocate) {
                page_table = @ptrCast(try page_allocator.allocate(0));
                @memset(mem.asBytes(page_table), 0);
                pte.physical_page_number = PhysicalPageNumber.fromPageTable(page_table);
                pte.permissions = .{ .valid = true };
            } else {
                return error.NotMapped;
            }
        }
        const leaf_index = PageTable.index(virtual, 0);
        return &page_table.entries[leaf_index];
    }

    pub fn index(virtual: ConstPagePtr, level: Level) Index {
        return @intCast((@intFromPtr(virtual) >> (12 + @as(u6, 9) * level)) & 0b111111111);
    }

    comptime {
        assert(@sizeOf(PageTable) == @sizeOf(Page));
    }
};

pub const PhysicalPageNumber = packed struct(u44) {
    ppn: u44,

    pub fn fromPageTable(pt: PageTable.Ptr) PhysicalPageNumber {
        return .{ .ppn = @intCast(physicalFromLogical(@intFromPtr(pt)) >> 12) };
    }

    pub fn fromPageFrame(physical: ConstPageFramePtr) PhysicalPageNumber {
        return .{ .ppn = @intCast(@intFromPtr(physical) >> 12) };
    }

    pub fn toPageTable(self: PhysicalPageNumber) PageTable.Ptr {
        return @ptrFromInt(logicalFromPhysical(@as(PhysicalAddress, self.ppn) << 12));
    }

    pub fn toPageFrame(self: PhysicalPageNumber) PageFramePtr {
        return @ptrFromInt(@as(PhysicalAddress, self.ppn) << 12);
    }
};

pub var ram_physical_slice: PageFrameSlice = undefined;
pub const user_virtual_end: UserVirtualAddress = libt.address_space_end;
pub const logical_start: LogicalAddress = 0xFFFFFFC000000000;
pub var logical_size: usize = undefined; // In pages.
pub var logical_offset: usize = 0;
pub const kernel_start: KernelVirtualAddress = 0xFFFFFFFFFF000000;
pub var kernel_size: usize = undefined; // In pages.
pub var kernel_offset: usize = 0;

const KERNEL_STACK_SIZE_TOTAL = proc.MAX_HARTS * entry.KERNEL_STACK_SIZE_PER_HART;
export var kernel_stack: [KERNEL_STACK_SIZE_TOTAL]u8 linksection(".bss") = undefined;

pub fn init(
    heap: PageFrameSlice,
    tix: PageFrameSlice,
    fdt: PageFrameSlice,
    out_tix_allocations: *PageSlice,
    out_fdt_allocations: *PageSlice,
) void {
    log.info("Initializing memory subsystem.", .{});
    page_allocator.init(heap, tix, fdt, out_tix_allocations, out_fdt_allocations);
    Region.init();
}

pub fn kernelVirtualFromPhysical(physical: anytype) @TypeOf(physical) {
    return switch (@typeInfo(@TypeOf(physical))) {
        .Int => physical +% kernel_offset,
        .Pointer => @ptrFromInt(@intFromPtr(physical) +% kernel_offset),
        else => @compileError("Argument must be an integer or a pointer."),
    };
}

pub fn physicalFromKernelVirtual(kernel_virtual: anytype) @TypeOf(kernel_virtual) {
    return switch (@typeInfo(@TypeOf(kernel_virtual))) {
        .Int => kernel_virtual -% kernel_offset,
        .Pointer => @ptrFromInt(@intFromPtr(kernel_virtual) -% kernel_offset),
        else => @compileError("Argument must be an integer or a pointer."),
    };
}

pub fn logicalFromPhysical(physical: anytype) @TypeOf(physical) {
    return switch (@typeInfo(@TypeOf(physical))) {
        .Int => physical +% logical_offset,
        .Pointer => @ptrFromInt(@intFromPtr(physical) +% logical_offset),
        else => @compileError("Argument must be an integer or a pointer."),
    };
}

pub fn physicalFromLogical(logical: anytype) @TypeOf(logical) {
    return switch (@typeInfo(@TypeOf(logical))) {
        .Int => logical -% logical_offset,
        .Pointer => @ptrFromInt(@intFromPtr(logical) -% logical_offset),
        else => @compileError("Argument must be an integer or a pointer."),
    };
}

pub fn pageSlicesOverlap(a: PageSlice, b: PageSlice) bool {
    const a_start = @intFromPtr(a.ptr);
    const a_end = a_start + a.len;
    const b_start = @intFromPtr(b.ptr);
    const b_end = b_start + b.len;
    return a_start < b_end and a_end > b_start;
}
