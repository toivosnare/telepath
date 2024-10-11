const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const mem = std.mem;
const mm = @import("../mm.zig");
const proc = @import("../proc.zig");
const riscv = @import("../riscv.zig");
const libt = @import("libt");
const Region = mm.Region;
const PhysicalAddress = mm.PhysicalAddress;
const UserVirtualAddress = mm.UserVirtualAddress;
const LogicalAddress = mm.LogicalAddress;
const Page = mm.Page;
const ConstPagePtr = mm.ConstPagePtr;
const PageSlice = mm.PageSlice;
const ConstPageFramePtr = mm.ConstPageFramePtr;
const PageTable = mm.PageTable;
const Futex = proc.Futex;
const Spinlock = libt.sync.Spinlock;
const Process = @This();

lock: Spinlock,
id: Id,
parent: ?*Process,
children: Children,
state: State,
region_entries: [max_regions]RegionEntry,
region_entries_head: ?*RegionEntry,
page_table: PageTable.Ptr,
context: Context,
wait_reason_count: usize,
wait_reasons: [max_wait_reasons]WaitReason,
wait_reasons_user: []libt.syscall.WaitReason,
wait_all: bool,
wait_timeout_next: ?*Process,
wait_timeout_time: u64,
scheduler_next: ?*Process,
killed: bool,

const max_children = 16;
const max_regions = 32;
const max_wait_reasons = 8;

pub const Id = usize;
pub const Children = std.BoundedArray(*Process, max_children);
pub const State = enum {
    invalid,
    ready,
    waiting,
    running,
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

    /// Check whether the region entry contains the given user virtual address
    /// and if so return corresponding physical address or null otherwise.
    pub fn contains(self: RegionEntry, address: UserVirtualAddress) ?PhysicalAddress {
        if (self.start_address == null)
            return null;
        if (self.start_address.? > address)
            return null;
        assert(self.region != null);
        const end_address = self.start_address.? + self.region.?.sizeInBytes();
        if (end_address <= address)
            return null;

        const offset_from_region_start = address - self.start_address.?;
        return @intFromPtr(self.region.?.allocation.ptr) + offset_from_region_start;
    }

    pub fn virtualSlice(self: RegionEntry) ?PageSlice {
        if (self.start_address == null)
            return null;
        if (self.region == null)
            return null;

        var result: PageSlice = undefined;
        result.ptr = @ptrFromInt(self.start_address.?);
        result.len = self.region.?.size;
        return result;
    }
};
pub const Context = extern struct {
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
    hart_index: proc.Hart.Index,

    pub fn process(self: *Context) *Process {
        return @fieldParentPtr("context", self);
    }
};

pub const WaitReason = struct {
    completed: bool,
    result: usize,
    payload: union(Tag) {
        pub const Tag = enum {
            none,
            futex,
            child_process,
        };
        none: void,
        futex: struct {
            address: PhysicalAddress,
            next: ?*WaitReason,
        },
        child_process: Process.Id,
    },
};

pub fn allocateRegion(
    self: *Process,
    size: usize,
    permissions: RegionEntry.Permissions,
    physical_address: PhysicalAddress,
) !*RegionEntry {
    for (&self.region_entries) |*re| {
        if (re.region == null) {
            // TODO: add physical address permissions.
            const region = try Region.allocate(size, physical_address);
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
    return error.OutOfMemory;
}

pub fn mapRegion(self: *Process, region: *Region, address: UserVirtualAddress) !UserVirtualAddress {
    const region_entry = self.hasRegion(region) orelse return error.NoPermission;
    if (region_entry.start_address != null)
        return error.Exists;
    return self.mapRegionEntry(region_entry, address);
}

pub fn mapRegionEntry(self: *Process, region_entry: *RegionEntry, address: UserVirtualAddress) !UserVirtualAddress {
    if (address == 0) {
        return self.mapRegionEntryWherever(region_entry);
    } else {
        if (!mem.isAligned(address, @sizeOf(Page)))
            return error.InvalidParameter;
        try self.mapRegionEntryAtAddress(region_entry, address);
        return address;
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
    if (region_end > mm.user_virtual_end)
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
    if (address + region_size > mm.user_virtual_end)
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
        region.ref();
        return re;
    }
    return error.OutOfMemory;
}

pub fn unmapRegionEntry(self: *Process, region_entry: *RegionEntry) !void {
    assert(region_entry.region != null);

    if (region_entry.start_address == null)
        return error.Exists;

    if (region_entry.prev) |prev| {
        prev.next = region_entry.next;
    } else {
        self.region_entries_head = region_entry.next;
    }
    if (region_entry.next) |next|
        next.prev = region_entry.prev;
    region_entry.prev = null;
    region_entry.next = null;

    const virtual = region_entry.virtualSlice() orelse unreachable;
    self.page_table.unmapRange(virtual);
    region_entry.start_address = null;
    riscv.@"sfence.vma"(null, null);
}

pub fn freeRegionEntry(self: *Process, region_entry: *RegionEntry) !void {
    _ = self;
    if (region_entry.start_address != null)
        return error.Exists;
    assert(region_entry.region != null);
    region_entry.region.?.unref();
    region_entry.region = null;
}

pub fn handlePageFault(self: *Process, faulting_address: UserVirtualAddress, kind: enum { load, store, execute }) noreturn {
    if (faulting_address >= mm.user_virtual_end)
        @panic("non user virtual address faulting");

    var entry: ?*RegionEntry = self.region_entries_head;
    while (entry) |e| : (entry = e.next) {
        assert(e.start_address != null);
        if (e.contains(faulting_address)) |corresponding_address| {
            if (kind == .load and !e.permissions.readable)
                break;
            if (kind == .store and !e.permissions.writable)
                break;
            if (kind == .execute and !e.permissions.executable)
                break;

            const virtual: ConstPagePtr = @ptrFromInt(mem.alignBackward(UserVirtualAddress, faulting_address, @sizeOf(Page)));
            const physical: ConstPageFramePtr = @ptrFromInt(mem.alignBackward(PhysicalAddress, corresponding_address, @sizeOf(Page)));
            self.page_table.map(virtual, physical, .{
                .valid = true,
                .readable = e.permissions.readable,
                .writable = e.permissions.writable,
                .executable = e.permissions.executable,
                .user = true,
                .global = false,
            }) catch @panic("OOM");
            riscv.@"sfence.vma"(faulting_address, null);
            proc.scheduler.scheduleCurrent(self);
        }
    }
    self.exit(libt.syscall.packResult(error.Crashed));
    proc.scheduler.scheduleNext(null, self.context.hart_index);
}

pub fn waitChildProcess(self: *Process, child_pid: Process.Id) !void {
    if (self.hasChildWithId(child_pid) == null) {
        log.warn("Process id={d} tried to wait on Process id={d} which is not a child", .{ self.id, child_pid });
        return error.NoPermission;
    }

    const wait_reason = try self.waitReasonAllocate();
    wait_reason.payload = .{ .child_process = child_pid };
}

pub fn waitReasonAllocate(self: *Process) !*WaitReason {
    if (self.wait_reason_count == max_wait_reasons) {
        log.warn("Process id={d} has no free wait reasons", .{self.id});
        return error.OutOfMemory;
    }

    const wait_reason = &self.wait_reasons[self.wait_reason_count];
    wait_reason.completed = false;
    wait_reason.result = 0;
    wait_reason.payload = .{ .none = {} };
    self.wait_reason_count += 1;
    return wait_reason;
}

pub fn waitCheck(self: *Process) void {
    if (self.wait_all) {
        for (self.waitReasons()) |*wait_reason| {
            if (!wait_reason.completed)
                return;
        }
    } else {
        self.waitReasonsClear();
    }
    proc.timeout.remove(self);
    proc.scheduler.enqueue(self);
}

pub fn waitReasonsClear(self: *Process) void {
    for (self.waitReasons()) |*wait_reason| {
        if (wait_reason.payload == .futex and !wait_reason.completed) {
            Futex.remove(self, wait_reason.payload.futex.address);
        } else if (wait_reason.payload == .child_process) {
            wait_reason.payload.child_process = 0;
        }
    }
}

pub fn waitCopyResult(self: *Process) void {
    if (self.wait_reason_count == 0)
        return;

    if (self.wait_all) {
        var all_completed: bool = true;
        for (self.waitReasons(), self.wait_reasons_user) |*kernel, *user| {
            if (kernel.completed) {
                user.result = kernel.result;
            } else {
                all_completed = false;
            }
        }
        if (all_completed)
            self.context.a0 = self.wait_reason_count;
    } else {
        for (0.., self.waitReasons(), self.wait_reasons_user) |index, *kernel, *user| {
            if (kernel.completed) {
                user.result = kernel.result;
                self.context.a0 = index;
                break;
            }
        }
    }
    self.waitClear();
}

pub fn waitClear(self: *Process) void {
    self.wait_reason_count = 0;
    for (&self.wait_reasons) |*wait_reason| {
        wait_reason.completed = false;
        wait_reason.result = 0;
        wait_reason.payload = .{ .none = {} };
    }
    self.wait_reasons_user = undefined;
    self.wait_all = false;
    self.wait_timeout_next = null;
    self.wait_timeout_time = 0;
}

fn waitReasons(self: *Process) []WaitReason {
    return (&self.wait_reasons)[0..self.wait_reason_count];
}

pub fn exit(self: *Process, exit_code: usize) void {
    const parent = self.parent orelse @panic("process with no parent exiting?");
    self.lock.unlock();

    parent.lock.lock();
    defer parent.lock.unlock();

    self.lock.lock();
    defer self.lock.unlock();

    if (self.killed) {
        proc.free(self);
        return;
    }

    for (parent.waitReasons()) |*wait_reason| {
        if (!wait_reason.completed and wait_reason.payload == .child_process and wait_reason.payload.child_process == self.id) {
            wait_reason.payload = .{ .child_process = 0 };
            wait_reason.completed = true;
            wait_reason.result = exit_code;
        }
    }
    parent.waitCheck();
    parent.kill(self);
}

pub fn kill(self: *Process, child: *Process) void {
    const child_index = mem.indexOfScalar(*Process, self.children.constSlice(), child) orelse unreachable;
    _ = self.children.swapRemove(child_index);
    child.die();
}

fn die(self: *Process) void {
    for (self.children.slice()) |child| {
        child.lock.lock();
        child.die();
        child.lock.unlock();
    }

    if (self.state == .ready) {
        proc.scheduler.remove(self);
    } else if (self.state == .waiting) {
        self.waitReasonsClear();
        proc.timeout.remove(self);
    } else if (self.state == .running) {
        self.killed = true;
        return;
    } else {
        assert(false);
    }

    proc.free(self);
}

pub fn hasRegion(self: *Process, region: *const Region) ?*RegionEntry {
    for (&self.region_entries) |*region_entry| {
        if (region_entry.region == region)
            return region_entry;
    }
    return null;
}

pub fn hasRegionAtAddress(self: *Process, address: UserVirtualAddress) ?*RegionEntry {
    for (&self.region_entries) |*region_entry| {
        if (region_entry.start_address == address)
            return region_entry;
    }
    return null;
}

pub fn hasChildWithId(self: Process, pid: Id) ?*Process {
    for (self.children.slice()) |child| {
        if (child.id == pid)
            return child;
    }
    return null;
}
