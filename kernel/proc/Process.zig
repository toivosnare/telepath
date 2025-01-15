const std = @import("std");
const log = std.log.scoped(.@"proc.Process");
const assert = std.debug.assert;
const mem = std.mem;
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const Handle = libt.Handle;
const riscv = @import("../riscv.zig");
const mm = @import("../mm.zig");
const Region = mm.Region;
const PhysicalAddress = mm.PhysicalAddress;
const VirtualAddress = mm.VirtualAddress;
const UserVirtualAddress = mm.UserVirtualAddress;
const Page = mm.Page;
const ConstPagePtr = mm.ConstPagePtr;
const ConstPageFramePtr = mm.ConstPageFramePtr;
const PageTable = mm.PageTable;
const proc = @import("../proc.zig");
const Thread = proc.Thread;
const Capability = proc.Capability;
const Process = @This();

lock: Spinlock,
id: Id,
ref_count: u8,
page_table: PageTable.Ptr,
process_caps_head: ?*Capability,
unmapped_region_caps_head: ?*Capability,
mapped_region_caps_head: ?*Capability,
thread_caps_head: ?*Capability,

pub const Id = usize;

pub fn ref(self: *Process) void {
    self.ref_count += 1;
}

pub fn unref(self: *Process) void {
    self.ref_count -= 1;
    if (self.ref_count == 0)
        proc.freeProcess(self);
}

pub fn allocateProcess(self: *Process) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    const process = try proc.allocateProcess();
    errdefer proc.freeProcess(process);

    const capability = try Capability.allocate();
    capability.owner = self;
    capability.permissions = .{ .share = true };
    capability.object = .{ .process = process };
    capability.start_address = null;

    // Prepend to process capability list.
    capability.next = self.process_caps_head;
    self.process_caps_head = capability;

    return capability.toHandle();
}

pub fn freeProcess(self: *Process, target_process_handle: Handle) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const target_process_capability = try Capability.get(target_process_handle, self);
    const target_process = try target_process_capability.process(self);

    if (target_process == self)
        return error.InvalidParameter;

    // Remove from process capability list.
    var prev: ?*Capability = null;
    var curr: ?*Capability = self.process_caps_head;
    while (curr) |c| {
        if (c == target_process_capability) {
            if (prev) |p| {
                p.next = target_process_capability.next;
            } else {
                self.process_caps_head = target_process_capability.next;
            }
            break;
        }

        prev = c;
        curr = c.next;
    } else @panic("process capability not in list");

    target_process_capability.free();
}

pub fn shareProcess(
    self: *Process,
    target_process_handle: Handle,
    recipient_process: *Process,
    permissions: libt.syscall.ProcessPermissions,
) !Handle {
    const target_process: *Process = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        if (recipient_process == self)
            return error.InvalidParameter;

        const target_process_capability = try Capability.get(target_process_handle, self);
        if (permissions.share and !target_process_capability.permissions.share)
            return error.NoPermission;

        break :blk try target_process_capability.process(self);
    };
    return recipient_process.receiveProcess(target_process, permissions);
}

fn receiveProcess(
    self: *Process,
    target_process: *Process,
    permissions: libt.syscall.ProcessPermissions,
) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.hasProcess(target_process)) |old_capability| {
        const old_permissions = &old_capability.permissions;
        old_permissions.* = .{
            .share = old_permissions.share or permissions.share,
        };

        return old_capability.toHandle();
    } else {
        const new_capability = try Capability.allocate();
        new_capability.owner = self;
        new_capability.permissions = .{
            .share = permissions.share,
        };
        new_capability.object = .{ .process = target_process };
        new_capability.start_address = null;
        target_process.ref();

        // Prepend to process capability list.
        new_capability.next = self.process_caps_head;
        self.process_caps_head = new_capability;

        return new_capability.toHandle();
    }
}

fn hasProcess(self: *Process, other: *Process) ?*Capability {
    var cap: ?*Capability = self.process_caps_head;
    while (cap) |c| : (cap = c.next) {
        if (c.object.process == other)
            return c;
    }
    return null;
}

pub fn translate(self: *Process, virtual_address: UserVirtualAddress) !PhysicalAddress {
    self.lock.lock();
    defer self.lock.unlock();

    var cap: ?*Capability = self.mapped_region_caps_head;
    while (cap) |c| : (cap = c.next) {
        // if (cap.start_address >= virtual_address)
        //     break;
        if (c.contains(virtual_address)) |physical_address| {
            return physical_address;
        } else |err| {
            switch (err) {
                error.No => continue,
                error.InvalidType => @panic(""),
            }
        }
    }
    return error.NotMapped;
}

pub fn allocateRegion(
    self: *Process,
    size: usize,
    permissions: libt.syscall.RegionPermissions,
    physical_address: PhysicalAddress,
) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    const region = try Region.allocate(size, physical_address);
    errdefer region.unref();

    const capability = try Capability.allocate();
    capability.owner = self;
    capability.permissions = .{
        .read = permissions.read,
        .write = permissions.write,
        .execute = permissions.execute,
    };
    capability.object = .{ .region = region };
    capability.start_address = null;

    // Prepend to unmapped region capability list.
    capability.next = self.unmapped_region_caps_head;
    self.unmapped_region_caps_head = capability;

    return capability.toHandle();
}

pub fn freeRegion(self: *Process, target_region_handle: Handle) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const target_region_capability = try Capability.get(target_region_handle, self);
    if (target_region_capability.object != .region)
        return error.InvalidType;
    if (target_region_capability.start_address != null)
        return error.Mapped;

    // Remove from unmapped region capability list.
    var prev: ?*Capability = null;
    var curr: ?*Capability = self.unmapped_region_caps_head;
    while (curr) |c| {
        if (c == target_region_capability) {
            if (prev) |p| {
                p.next = target_region_capability.next;
            } else {
                self.unmapped_region_caps_head = target_region_capability.next;
            }
            break;
        }

        prev = c;
        curr = c.next;
    } else @panic("region capability not in list");

    target_region_capability.free();
}

pub fn shareRegion(
    self: *Process,
    target_region_handle: Handle,
    recipient_process: *Process,
    permissions: libt.syscall.RegionPermissions,
) !Handle {
    const target_region: *Region = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        if (recipient_process == self)
            return error.InvalidParameter;

        const target_region_capability = try Capability.get(target_region_handle, self);
        if (permissions.read and !target_region_capability.permissions.read)
            return error.NoPermission;
        if (permissions.write and !target_region_capability.permissions.write)
            return error.NoPermission;
        if (permissions.execute and !target_region_capability.permissions.execute)
            return error.NoPermission;

        break :blk try target_region_capability.region();
    };
    return recipient_process.receiveRegion(target_region, permissions);
}

fn receiveRegion(
    self: *Process,
    target_region: *Region,
    permissions: libt.syscall.RegionPermissions,
) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.hasRegion(target_region)) |old_capability| {
        const old_permissions = &old_capability.permissions;
        old_permissions.* = .{
            .read = old_permissions.read or permissions.read,
            .write = old_permissions.write or permissions.write,
            .execute = old_permissions.execute or permissions.execute,
        };

        return old_capability.toHandle();
    } else {
        const new_capability = try Capability.allocate();
        new_capability.owner = self;
        new_capability.permissions = .{
            .read = permissions.read,
            .write = permissions.write,
            .execute = permissions.execute,
        };
        new_capability.object = .{ .region = target_region };
        new_capability.start_address = null;
        target_region.ref();

        // Prepend to unmapped region capability list.
        new_capability.next = self.unmapped_region_caps_head;
        self.unmapped_region_caps_head = new_capability;

        return new_capability.toHandle();
    }
}

fn hasRegion(self: *Process, other: *Region) ?*Capability {
    var cap: ?*Capability = self.unmapped_region_caps_head;
    while (cap) |c| : (cap = c.next) {
        if (c.object.region == other)
            return c;
    }

    cap = self.mapped_region_caps_head;
    while (cap) |c| : (cap = c.next) {
        if (c.object.region == other)
            return c;
    }

    return null;
}

pub fn mapRegion(self: *Process, target_region_handle: Handle, virtual_address: UserVirtualAddress) !UserVirtualAddress {
    self.lock.lock();
    defer self.lock.unlock();

    const target_region_capability = try Capability.get(target_region_handle, self);
    if (target_region_capability.object != .region)
        return error.InvalidType;
    if (target_region_capability.start_address != null)
        return error.Mapped;
    if (!mem.isAligned(virtual_address, @sizeOf(Page)))
        return error.InvalidParameter;

    const next = target_region_capability.next;

    const result = try if (virtual_address == 0)
        self.mapRegionWherever(target_region_capability)
    else
        self.mapRegionAt(target_region_capability, virtual_address);

    // Remove from unmapped regions caps list.
    var prev: ?*Capability = null;
    var curr: ?*Capability = self.unmapped_region_caps_head;
    while (curr) |c| {
        if (c == target_region_capability)
            break;
        prev = c;
        curr = c.next;
    } else @panic("");

    if (prev) |p| {
        p.next = next;
    } else {
        self.unmapped_region_caps_head = next;
    }

    return result;
}

/// Find the first large enough free space in the process address space that can hold the new region.
fn mapRegionWherever(self: *Process, region_capability: *Capability) !UserVirtualAddress {
    const region = region_capability.object.region;
    const region_size = region.sizeInBytes();

    // Skip the first page to avoid null pointer dereference problems.
    var candidate_address: UserVirtualAddress = @sizeOf(Page);
    var prev_cap: ?*Capability = null;
    var next_cap: ?*Capability = self.mapped_region_caps_head;
    while (next_cap) |nc| {
        if (nc.start_address.? - candidate_address >= region_size)
            break;
        candidate_address = nc.start_address.? + nc.object.region.sizeInBytes();
        prev_cap = nc;
        next_cap = nc.next;
    }
    if (candidate_address + region_size > mm.user_virtual_end) {
        log.warn("Process id={d} map failed because address space is reserved", .{self.id});
        return error.Reserved;
    }

    // Update the mapped region capability list.
    region_capability.next = next_cap;
    if (prev_cap) |pc| {
        pc.next = region_capability;
    } else {
        self.mapped_region_caps_head = region_capability;
    }

    region_capability.start_address = candidate_address;
    return candidate_address;
}

fn mapRegionAt(self: *Process, region_capability: *Capability, address: UserVirtualAddress) !UserVirtualAddress {
    // Find region capabilities that are mapped before (prev_cap) and after (next_cap) the new region.
    var addr: UserVirtualAddress = 0;
    var prev_cap: ?*Capability = null;
    var prev_size: usize = undefined;
    var next_cap: ?*Capability = self.mapped_region_caps_head;
    while (next_cap) |nc| {
        if (nc.start_address.? >= address)
            break;
        prev_size = nc.object.region.sizeInBytes();
        addr = nc.start_address.? + prev_size;
        prev_cap = nc;
        next_cap = nc.next;
    }

    // Check that the region mapping fits between the prev_cap and next_cap.
    const region = region_capability.object.region;
    const region_end = address + region.sizeInBytes();
    if (prev_cap) |pc| {
        if (pc.start_address.? + prev_size > address) {
            log.warn("Process id={d} map failed because address space is reserved", .{self.id});
            return error.Reserved;
        }
    }
    if (next_cap) |nc| {
        if (region_end > nc.start_address.?) {
            log.warn("Process id={d} map failed because address space is reserved", .{self.id});
            return error.Reserved;
        }
    }

    // Check that the region mapping would not go past the user virtual address space end.
    if (region_end > mm.user_virtual_end) {
        log.warn("Process id={d} map failed because address space is reserved", .{self.id});
        return error.Reserved;
    }

    // Update the mapped region capabilities list.
    if (prev_cap) |pc| {
        pc.next = region_capability;
    } else {
        self.mapped_region_caps_head = region_capability;
    }
    region_capability.next = next_cap;

    region_capability.start_address = address;
    return address;
}

pub fn unmapRegion(self: *Process, virtual_address: UserVirtualAddress) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    // log.debug("Process id={d} is unmapping RegionEntry for Region index={d}", .{ self.id, region_entry.region.?.index() });
    var prev_cap: ?*Capability = null;
    var curr_cap: ?*Capability = self.mapped_region_caps_head;
    const region_capability: *Capability = while (curr_cap) |cc| {
        if (cc.start_address.? == virtual_address)
            break cc;
        if (cc.start_address.? > virtual_address)
            return error.InvalidParameter;

        prev_cap = cc;
        curr_cap = cc.next;
    } else return error.InvalidParameter;

    // Remove the region capability form the mapped region capabilities list.
    if (prev_cap) |pc| {
        pc.next = region_capability.next;
    } else {
        self.mapped_region_caps_head = region_capability.next;
    }

    // Prepend to unmapped region capability list.
    region_capability.next = self.unmapped_region_caps_head;
    self.unmapped_region_caps_head = region_capability;

    const virtual_slice = region_capability.virtualSlice() catch unreachable;
    self.page_table.unmapRange(virtual_slice);
    region_capability.start_address = null;
    riscv.@"sfence.vma"(null, null);
    return region_capability.toHandle();
}

pub fn writeRegion(self: *Process, target_region_handle: Handle, from: UserVirtualAddress, offset: usize, length: usize) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const target_region_capability = try Capability.get(target_region_handle, self);
    const target_region = try target_region_capability.region();
    try target_region.write(from, offset, length);
}

pub fn sizeRegion(self: *Process, target_region_handle: Handle) !usize {
    self.lock.lock();
    defer self.lock.unlock();

    const target_region_capability = try Capability.get(target_region_handle, self);
    const target_region = try target_region_capability.region();
    return target_region.size;
}

pub fn allocateThread(
    self: *Process,
    target_process_handle: Handle,
    instruction_pointer: usize,
    stack_pointer: usize,
    a0: usize,
    a1: usize,
) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    const target_process_capability = try Capability.get(target_process_handle, self);
    const target_process = try target_process_capability.process(self);

    const thread = try proc.allocateThread();
    errdefer proc.freeThread(thread);

    const capability = try Capability.allocate();
    capability.owner = self;
    capability.permissions = .{ .wait = true, .kill = true };
    capability.object = .{ .thread = thread };
    capability.start_address = null;

    // Prepend to thread capability list.
    capability.next = self.thread_caps_head;
    self.thread_caps_head = capability;

    thread.process = target_process;
    target_process.ref();
    thread.context.pc = instruction_pointer;
    thread.context.sp = stack_pointer;
    thread.context.a0 = a0;
    thread.context.a1 = a1;
    proc.scheduler.enqueue(thread);

    return capability.toHandle();
}

pub fn freeThread(self: *Process, target_thread_handle: Handle) !void {
    self.lock.lock();
    defer self.lock.unlock();

    const target_thread_capability = try Capability.get(target_thread_handle, self);
    if (target_thread_capability.object != .thread)
        return error.InvalidType;

    // Remove from thread capability list.
    var prev: ?*Capability = null;
    var curr: ?*Capability = self.thread_caps_head;
    while (curr) |c| {
        if (c == target_thread_capability) {
            if (prev) |p| {
                p.next = target_thread_capability.next;
            } else {
                self.process_caps_head = target_thread_capability.next;
            }
            break;
        }

        prev = c;
        curr = c.next;
    } else @panic("thread capability not in list");

    target_thread_capability.free();
}

pub fn shareThread(
    self: *Process,
    target_thread_handle: Handle,
    recipient_process: *Process,
    permissions: libt.syscall.ThreadPermissions,
) !Handle {
    const target_thread: *Thread = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        if (recipient_process == self)
            return error.InvalidParameter;

        const target_thread_capability = try Capability.get(target_thread_handle, self);
        if (permissions.wait and !target_thread_capability.permissions.wait)
            return error.NoPermission;
        if (permissions.kill and !target_thread_capability.permissions.kill)
            return error.NoPermission;

        break :blk try target_thread_capability.thread();
    };
    return recipient_process.receiveThread(target_thread, permissions);
}

fn receiveThread(
    self: *Process,
    target_thread: *Thread,
    permissions: libt.syscall.ThreadPermissions,
) !Handle {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.hasThread(target_thread)) |old_capability| {
        const old_permissions = &old_capability.permissions;
        old_permissions.* = .{
            .wait = old_permissions.wait or permissions.wait,
            .kill = old_permissions.kill or permissions.kill,
        };

        return old_capability.toHandle();
    } else {
        const new_capability = try Capability.allocate();
        new_capability.owner = self;
        new_capability.permissions = .{
            .wait = permissions.wait,
            .kill = permissions.kill,
        };
        new_capability.object = .{ .thread = target_thread };
        new_capability.start_address = null;
        target_thread.ref();

        // Prepend to thread capability list.
        new_capability.next = self.thread_caps_head;
        self.thread_caps_head = new_capability;

        return new_capability.toHandle();
    }
}

fn hasThread(self: *Process, thread: *Thread) ?*Capability {
    var cap: ?*Capability = self.thread_caps_head;
    while (cap) |c| : (cap = c.next) {
        if (c.object.thread == thread)
            return c;
    }
    return null;
}

pub fn killThread(self: *Process, target_thread_handle: Handle, exit_code: usize) !void {
    const target_thread = blk: {
        self.lock.lock();
        defer self.lock.unlock();

        const target_thread_capability = try Capability.get(target_thread_handle, self);
        break :blk try target_thread_capability.thread();
    };

    // TODO: holding two thread locks here?
    target_thread.lock.lock();
    target_thread.die(exit_code);
    target_thread.lock.unlock();
}

pub const PageFaultKind = enum { load, store, execute };
pub fn handlePageFault(self: *Process, faulting_address: VirtualAddress, kind: PageFaultKind) bool {
    self.lock.lock();
    defer self.lock.unlock();

    if (faulting_address >= mm.user_virtual_end)
        @panic("non user virtual address faulting");

    log.debug("Process id={d} handling page fault for address 0x{x}", .{ self.id, faulting_address });

    var region_cap: ?*Capability = self.mapped_region_caps_head;
    while (region_cap) |rc| : (region_cap = rc.next) {
        assert(rc.start_address != null);
        if (rc.contains(faulting_address)) |corresponding_address| {
            if (kind == .load and !rc.permissions.read) {
                log.warn("Process id={d} tried to read from address 0x{x} where it has no read permission", .{ self.id, faulting_address });
                break;
            }
            if (kind == .store and !rc.permissions.write) {
                log.warn("Process id={d} tried to write to address 0x{x} where it has no write permission", .{ self.id, faulting_address });
                break;
            }
            if (kind == .execute and !rc.permissions.execute) {
                log.warn("Process id={d} tried to execute from address 0x{x} where it has no execute permission", .{ self.id, faulting_address });
                break;
            }

            const virtual: ConstPagePtr = @ptrFromInt(mem.alignBackward(UserVirtualAddress, faulting_address, @sizeOf(Page)));
            const physical: ConstPageFramePtr = @ptrFromInt(mem.alignBackward(PhysicalAddress, corresponding_address, @sizeOf(Page)));
            self.page_table.map(virtual, physical, .{
                .valid = true,
                .readable = rc.permissions.read,
                .writable = rc.permissions.write,
                .executable = rc.permissions.execute,
                .user = true,
                .global = false,
            }) catch @panic("OOM");
            riscv.@"sfence.vma"(faulting_address, null);
            return true;
        } else |err| switch (err) {
            error.InvalidType => @panic(""),
            error.No => continue,
        }
    } else {
        log.warn("Process id={d} tried to access unmapped address 0x{x}", .{ self.id, faulting_address });
    }
    return false;
}
