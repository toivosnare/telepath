const log = @import("std").log;
const mm = @import("mm.zig");
const Process = @This();

id: Id,
parent_id: Id,
children: [MAX_CHILDREN]Id,
state: State,
mappings: [MAX_MAPPINGS]Mapping,
page_table: mm.PageTablePtr,
register_file: RegisterFile,

pub const Id = usize;
const State = enum {
    invalid,
    ready,
    running,
    waiting,
};
const Mapping = packed struct {
    region: *mm.Region,
    start_address: mm.VirtualAddress,
    readable: bool,
    writable: bool,
    executable: bool,
    valid: bool,

    pub fn isFree(self: Mapping) bool {
        return !self.valid;
    }
};
const RegisterFile = extern struct {
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
const MAX_CHILDREN = 16;
const MAX_MAPPINGS = 16;
const MAX_PROCESSES = 64;

var table: [MAX_PROCESSES]Process = undefined;

pub fn init() void {
    log.info("Initializing process subsystem.", .{});
    for (1.., &table) |id, *p| {
        p.id = id;
        p.state = .invalid;
        for (&p.children) |*c| {
            c.* = 0;
        }
        for (&p.mappings) |*m| {
            m.valid = false;
        }
    }
}

pub fn allocate() !*Process {
    for (&table) |*p| {
        if (p.state == .invalid) {
            p.state = .waiting;
            return p;
        }
    }
    return error.ProcessTableFull;
}

pub const MappingOptions = struct {
    region: *mm.Region,
    start_address: ?mm.VirtualAddress = null,
    readable: bool,
    writable: bool,
    executable: bool,
};
pub fn addMapping(self: *Process, options: MappingOptions) !*Mapping {
    for (&self.mappings) |*m| {
        if (!m.isFree())
            continue;
        const addr = options.start_address orelse
            findFreeVirtualSection() catch |e| return e;
        m.* = .{
            .region = options.region,
            .start_address = addr,
            .readable = options.readable,
            .writable = options.writable,
            .executable = options.executable,
            .valid = true,
        };
        return m;
    }
    return error.MappingTableFull;
}

fn findFreeVirtualSection() !mm.VirtualAddress {
    // TODO: implement.
    return error.VirtualAddressSpaceFull;
}
