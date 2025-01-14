const std = @import("std");
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const Handle = libt.Handle;
const proc = @import("../proc.zig");
const Process = proc.Process;
const Thread = proc.Thread;
const mm = @import("../mm.zig");
const Region = mm.Region;
const PageSlice = mm.PageSlice;
const UserVirtualAddress = mm.UserVirtualAddress;
const PhysicalAddress = mm.PhysicalAddress;
const Capability = @This();

owner: *Process,
permissions: Permissions,
object: Object,
/// Only relevant for region capabilities.
start_address: ?UserVirtualAddress,
next: ?*Capability,

const Object = union(Tag) {
    none: void,
    process: *Process,
    region: *Region,
    thread: *Thread,
    self: void,
};

const Permissions = packed struct {
    share: bool = false,
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    wait: bool = false,
    kill: bool = false,

    pub const all: Permissions = .{
        .share = true,
        .read = true,
        .write = true,
        .execute = true,
        .wait = true,
        .kill = true,
    };
};

pub const Tag = enum {
    none,
    process,
    region,
    thread,
    self,
};

const max_capabilities = 256;
var table: [max_capabilities]Capability = undefined;
var free_list_lock: Spinlock = .{};
var free_list_head: ?*Capability = undefined;

pub fn init() void {
    var prev: ?*Capability = null;
    var i: usize = 1;
    while (i < max_capabilities) : (i += 1) {
        const cap = &table[i];
        cap.owner = undefined;
        cap.permissions = .{};
        cap.object = .{ .none = {} };
        cap.start_address = null;
        if (prev) |p| {
            p.next = cap;
        } else {
            free_list_head = cap;
        }
        prev = cap;
    }

    // Handle 0 is always special self process capability.
    const self_cap = &table[0];
    self_cap.owner = undefined;
    self_cap.permissions = Permissions.all;
    // FIXME: compiler bug???
    // self_cap.object = .{ .self = {} };
    self_cap.object = @unionInit(Object, "self", {});
    self_cap.start_address = null;
    self_cap.next = null;
}

pub fn onAddressTranslationEnabled() void {
    free_list_head = mm.kernelVirtualFromPhysical(free_list_head.?);
    var cap: ?*Capability = free_list_head;
    while (cap) |c| : (cap = c.next) {
        if (c.next) |n| {
            c.next = mm.kernelVirtualFromPhysical(n);
        }
    }
}

pub fn allocate() !*Capability {
    free_list_lock.lock();
    defer free_list_lock.unlock();

    if (free_list_head) |head| {
        free_list_head = head.next;
        return head;
    }
    return error.OutOfMemory;
}

pub fn free(capability: *Capability) void {
    switch (capability.object) {
        .none => {},
        .process => |p| p.unref(),
        .region => |r| r.unref(),
        .thread => |t| t.unref(),
        .self => {},
    }

    free_list_lock.lock();
    defer free_list_lock.unlock();

    capability.owner = undefined;
    capability.object = .{ .none = {} };
    capability.start_address = null;
    capability.next = free_list_head;
    free_list_head = capability;
}

pub fn get(handle: Handle, owner: *Process) !*Capability {
    const handle_int = @intFromEnum(handle);
    if (handle_int >= max_capabilities)
        return error.InvalidParameter;

    const cap = &table[handle_int];
    if (handle != .self and cap.owner != owner)
        return error.NoPermission;

    return cap;
}

pub fn process(self: Capability, owner: *Process) !*Process {
    return switch (self.object) {
        .process => |p| p,
        .self => owner,
        else => error.InvalidType,
    };
}

pub fn region(self: Capability) !*Region {
    return switch (self.object) {
        .region => |r| r,
        else => error.InvalidType,
    };
}

pub fn thread(self: Capability) !*Thread {
    return switch (self.object) {
        .thread => |t| t,
        else => error.InvalidType,
    };
}

pub fn toHandle(capability: *const Capability) Handle {
    return @enumFromInt((@intFromPtr(capability) - @intFromPtr(&table)) / @sizeOf(Capability));
}

/// Check whether the mapping contains the given user virtual address
/// and if so return corresponding physical address or null otherwise.
pub fn contains(self: Capability, address: UserVirtualAddress) !PhysicalAddress {
    if (self.object != .region)
        return error.InvalidType;
    if (self.start_address == null)
        return error.No;
    if (self.start_address.? > address)
        return error.No;
    const end_address = self.start_address.? + self.object.region.sizeInBytes();
    if (end_address <= address)
        return error.No;

    const offset_from_region_start = address - self.start_address.?;
    return @intFromPtr(self.object.region.allocation.ptr) + offset_from_region_start;
}

pub fn virtualSlice(self: Capability) !PageSlice {
    if (self.object != .region)
        return error.InvalidType;
    if (self.start_address == null)
        return error.NotMapped;

    var result: PageSlice = undefined;
    result.ptr = @ptrFromInt(self.start_address.?);
    result.len = self.object.region.size;
    return result;
}
