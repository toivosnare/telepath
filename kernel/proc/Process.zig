const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const mem = std.mem;
const mm = @import("../mm.zig");
const proc = @import("../proc.zig");
const Region = mm.Region;
const UserVirtualAddress = mm.UserVirtualAddress;
const Page = mm.Page;
const PageTable = mm.PageTable;
const HartIndex = proc.HartIndex;
const Process = @This();

id: Id,
parent: ?*Process,
children: Children,
state: State,
region_entries: [MAX_REGIONS]RegionEntry,
region_entries_head: ?*RegionEntry,
page_table: PageTable.Ptr,
context: Context,
prev: ?*Process,
next: ?*Process,

const MAX_CHILDREN = 16;
const MAX_REGIONS = 16;

pub const Id = usize;
pub const Children = std.BoundedArray(*Process, MAX_CHILDREN);
pub const State = enum {
    invalid,
    ready,
    running,
    waiting,
};
pub const RegionEntry = struct {
    region: ?*Region,
    start_address: ?UserVirtualAddress,
    permissions: Permissions,
    prev: ?*RegionEntry,
    next: ?*RegionEntry,
    const Index = usize;
    const Permissions = struct {
        readable: bool = false,
        writable: bool = false,
        executable: bool = false,
    };
};
pub const Context = extern struct {
    register_file: RegisterFile,
    hart_index: HartIndex,

    pub const RegisterFile = extern struct {
        pc: usize,
        ra: usize,
        sp: usize,
        gp: usize,
        tp: usize,
        t0: usize,
        t1: usize,
        t2: usize,
        s0: usize,
        s1: usize,
        a0: usize,
        a1: usize,
        a2: usize,
        a3: usize,
        a4: usize,
        a5: usize,
        a6: usize,
        a7: usize,
        s2: usize,
        s3: usize,
        s4: usize,
        s5: usize,
        s6: usize,
        s7: usize,
        s8: usize,
        s9: usize,
        s10: usize,
        s11: usize,
        t3: usize,
        t4: usize,
        t5: usize,
        t6: usize,
    };

    pub fn process(self: *Context) *Process {
        return @fieldParentPtr("context", self);
    }
};

pub fn allocateRegion(self: *Process, size: usize, permissions: RegionEntry.Permissions) !*RegionEntry {
    for (&self.region_entries) |*re| {
        if (re.region == null) {
            const region = try Region.allocate(size);
            re.* = .{
                .region = region,
                .start_address = null,
                .permissions = permissions,
                .prev = null,
                .next = null,
            };
            return re;
        }
    }
    return error.RegionEntryTableFull;
}

pub fn mapRegion(self: *Process, region: *Region, address: ?UserVirtualAddress) !UserVirtualAddress {
    for (&self.region_entries) |*re| {
        if (re.region != region)
            continue;
        if (re.start_address != null)
            return error.AlreadyMapped;
        return self.mapRegionEntry(re, address);
    }
    return error.NoPermission;
}

pub fn mapRegionEntry(self: *Process, region_entry: *RegionEntry, address: ?UserVirtualAddress) !UserVirtualAddress {
    if (address) |addr| {
        try self.mapRegionEntryAtAddress(region_entry, addr);
        return addr;
    } else {
        return self.mapRegionEntryWherever(region_entry);
    }
}

fn mapRegionEntryAtAddress(self: *Process, region_entry: *RegionEntry, address: UserVirtualAddress) !void {
    // Find region entries that are mapped before (previous_entry) and after (next_entry) the new region.
    var addr: UserVirtualAddress = 0;
    var previous_entry: ?*RegionEntry = null;
    var previous_size: usize = undefined;
    var next_entry: ?*RegionEntry = self.region_entries_head;
    while (next_entry) |ne| {
        if (ne.start_address.? >= address)
            break;
        previous_size = ne.region.?.sizeInBytes();
        addr = ne.start_address.? + previous_size;
        previous_entry = ne;
        next_entry = ne.next;
    }

    // Check that the region mapping fits between the previous_entry and current_entry.
    const region = region_entry.region.?;
    const region_end = address + region.sizeInBytes();
    if (previous_entry) |pe| {
        if (pe.start_address.? + previous_size > address)
            return error.Reserved;
    }
    if (next_entry) |ne| {
        if (region_end > ne.start_address.?)
            return error.Reserved;
    }

    // Check that the region mapping would not go past the user virtual address space end.
    if (region_end > mm.max_user_virtual)
        return error.Reserved;

    // Update the region entry linked list.
    region_entry.start_address = address;
    region_entry.prev = previous_entry;
    if (previous_entry) |pe| {
        pe.next = region_entry;
    } else {
        self.region_entries_head = region_entry;
    }
    region_entry.next = next_entry;
    if (next_entry) |ne| {
        ne.prev = region_entry;
    }
}

fn mapRegionEntryWherever(self: *Process, region_entry: *RegionEntry) !UserVirtualAddress {
    // Find the first large enough free space in the process address space that can hold the new region.
    const region = region_entry.region.?;
    const region_size = region.sizeInBytes();
    // Skip the first page to avoid null pointer dereference problems.
    var address: UserVirtualAddress = @sizeOf(Page);
    var previous_entry: ?*RegionEntry = null;
    var next_entry: ?*RegionEntry = self.region_entries_head;
    while (next_entry) |ne| {
        if (ne.start_address.? - address >= region_size)
            break;
        address = ne.start_address.? + ne.region.?.sizeInBytes();
        previous_entry = ne;
        next_entry = ne.next;
    }
    if (address + region_size > mm.max_user_virtual)
        return error.Reserved;

    // Update the region entry linked list.
    region_entry.start_address = address;
    region_entry.prev = previous_entry;
    if (previous_entry) |pe| {
        pe.next = region_entry;
    } else {
        self.region_entries_head = region_entry;
    }
    region_entry.next = next_entry;
    if (next_entry) |ne| {
        ne.prev = region_entry;
    }
    return address;
}

pub fn receiveRegion(self: *Process, region: *Region, permissions: RegionEntry.Permissions) !*RegionEntry {
    var free_entry: ?*RegionEntry = null;
    for (&self.region_entries) |*re| {
        if (re.region == null) {
            free_entry = re;
        } else if (re.region == region) {
            re.permissions.readable = re.permissions.readable or permissions.readable;
            re.permissions.writable = re.permissions.writable or permissions.writable;
            re.permissions.executable = re.permissions.executable or permissions.executable;
            return re;
        }
    }
    if (free_entry) |re| {
        re.region = region;
        re.start_address = null;
        re.permissions = permissions;
        re.prev = null;
        re.next = null;
        return re;
    }
    return error.RegionEntryTableFull;
}

fn freeRegionEntry(self: *Process, region_entry: *RegionEntry) void {
    if (region_entry.region == null)
        return;
    if (region_entry.start_address != null) {
        self.unmapRegionEntry(region_entry);
    }
    region_entry.region.?.free();
    region_entry.region = null;
}

pub fn unmapRegion(self: *Process, region: *Region) void {
    for (&self.region_entries) |*re| {
        if (re.region != region)
            continue;
        if (re.start_address != null)
            self.unmapRegionEntry(re);
        return;
    }
}

pub fn unmapRegionEntry(self: *Process, region_entry: *RegionEntry) void {
    _ = self;
    assert(region_entry.start_address != null);
    // TODO: fix linked list.
    // TODO: unmap from page table.
    region_entry.start_address = null;
}

pub fn deinit(self: *Process) void {
    for (self.children.slice()) |child| {
        child.deinit();
    }
    self.state = .invalid;
    for (&self.region_entries) |*region_entry| {
        self.freeRegionEntry(region_entry);
    }
    self.region_entries_head = null;
    // TODO: page table?
    // slef.page_table = ;
    @memset(mem.asBytes(&self.context), 0);
    if (self.state == .ready)
        proc.dequeue(self);
}
