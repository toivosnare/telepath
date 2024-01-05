const std = @import("std");
const mm = @import("mm.zig");
const Process = @import("Process.zig");
const dtb = @import("dtb");
const libt = @import("libt");
const log = std.log;
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;
const PhysicalAddress = mm.PhysicalAddress;
const VirtualAddress = mm.VirtualAddress;
const PAGE_SIZE = mm.PAGE_SIZE;
const tix = libt.tix;

pub const std_options = struct {
    pub const logFn = @import("log.zig").logFn;
};


extern const kernel_linker_start: u8;
extern const kernel_linker_end: u8;

export fn main(kernel_physical_start: PhysicalAddress, fdt_physical_start: PhysicalAddress) noreturn {
    log.info("Kernel booting...", .{});
    const pr = parseFdt(fdt_physical_start);
    const kernel_size = @intFromPtr(&kernel_linker_end) - @intFromPtr(&kernel_linker_start);
    const kernel_physical_end = kernel_physical_start + kernel_size;
    const kernel_size_in_pages = math.divCeil(usize, kernel_size, PAGE_SIZE) catch unreachable;
    const heap_physical_start = mem.alignForward(PhysicalAddress, kernel_physical_end, PAGE_SIZE);
    const heap_physical_end = mem.alignBackward(PhysicalAddress, pr.ram_physical_end, PAGE_SIZE);
    assert(heap_physical_start < heap_physical_end);

    var kernel_physical_slice: mm.ConstPageFrameSlice = undefined;
    kernel_physical_slice.ptr = @ptrFromInt(kernel_physical_start);
    kernel_physical_slice.len = kernel_size_in_pages;

    var heap_physical_slice: mm.PageFrameSlice = undefined;
    heap_physical_slice.ptr = @ptrFromInt(heap_physical_start);
    heap_physical_slice.len = (heap_physical_end - heap_physical_start) / PAGE_SIZE;

    var fdt_physical_slice: mm.PageFrameSlice = undefined;
    fdt_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, fdt_physical_start, PAGE_SIZE));
    fdt_physical_slice.len = math.divCeil(usize, pr.fdt_size, PAGE_SIZE) catch unreachable;

    var initrd_physical_slice: mm.PageFrameSlice = undefined;
    initrd_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, pr.initrd_physical_start, PAGE_SIZE));
    initrd_physical_slice.len = math.divCeil(usize, pr.initrd_size, PAGE_SIZE) catch unreachable;

    mm.init(heap_physical_slice, fdt_physical_slice, initrd_physical_slice);
    Process.init();

    const init_process = Process.allocate() catch @panic("process table full");
    const page_table: mm.PageTablePtr = @ptrCast(mm.page_allocator.allocate() catch @panic("OOM"));
    @memset(mem.asBytes(page_table), 0);
    mm.mapKernel(page_table, kernel_physical_slice);
    init_process.page_table = page_table;

    const tix_header: *tix.Header = @ptrFromInt(pr.initrd_physical_start);
    if (!mem.eql(u8, &tix_header.magic, &tix.Header.MAGIC))
        @panic("Invalid TIX magic.");
    init_process.register_file.pc = tix_header.entry_point;
    var region_headers: []tix.RegionHeader = undefined;
    region_headers.ptr = @ptrFromInt(pr.initrd_physical_start + @sizeOf(tix.Header));
    region_headers.len = tix_header.region_amount;
    for (region_headers) |rh| {
        log.debug("{}", .{rh});
        const region_physical_start: PhysicalAddress = pr.initrd_physical_start + rh.offset;
        const region: *mm.Region = mm.Region.allocate() catch @panic("region table full");

        var addr: mm.Address = rh.load_address;
        var region_offset: usize = 0;
        while (addr < rh.load_address + rh.size) : (addr = mem.alignBackward(mm.Address, addr, PAGE_SIZE) + PAGE_SIZE) {
            const page_frame: mm.PageFramePtr = mm.page_allocator.allocate() catch @panic("OOM");
            region.addPageFrame(page_frame) catch @panic("init page frame table full");

            const page_offset = addr % PAGE_SIZE;
            const byte_count = @min(PAGE_SIZE - page_offset, rh.size - region_offset);

            var dest: []u8 = undefined;
            dest.ptr = @ptrFromInt(@intFromPtr(page_frame) + page_offset);
            dest.len = byte_count;
            const source: [*]u8 = @ptrFromInt(region_physical_start + region_offset);
            @memcpy(dest, source);
            log.debug("Copied {} bytes from {*} to {*}", .{ byte_count, source, dest.ptr });

            region_offset += byte_count;
        }

        _ = init_process.addMapping(.{
            .region = region,
            .start_address = mem.alignBackward(VirtualAddress, rh.load_address, PAGE_SIZE),
            .readable = rh.readable,
            .writable = rh.writable,
            .executable = rh.executable,
        }) catch @panic("init mapping table full");
    }
    mm.page_allocator.freeSlice(initrd_physical_slice);

    const fdt_region = mm.Region.allocate() catch @panic("region table full");
    fdt_region.addPageFrames(fdt_physical_slice) catch @panic("init fdt page frame table full");
    const fdt_mapping = init_process.addMapping(.{
        .region = fdt_region,
        .readable = true,
        .writable = true,
        .executable = false,
    }) catch @panic("init mapping table full");
    const fdt_page_offset = fdt_physical_start % PAGE_SIZE;
    const fdt_virtual_start = fdt_mapping.start_address + fdt_page_offset;
    init_process.register_file.a0 = fdt_virtual_start;

    while (true) {}
}

const FdtParseResult = struct {
    fdt_size: usize,
    fdt_physical_end: PhysicalAddress,
    initrd_physical_start: PhysicalAddress,
    initrd_size: usize,
    initrd_physical_end: PhysicalAddress,
    ram_physical_start: PhysicalAddress,
    ram_size: usize,
    ram_physical_end: PhysicalAddress,
    plic_physical_start: PhysicalAddress,
    plic_size: usize,
    plic_physical_end: PhysicalAddress,
    clint_physical_start: PhysicalAddress,
    clint_size: usize,
    clint_physical_end: PhysicalAddress,
};
fn parseFdt(fdt_physical_start: PhysicalAddress) FdtParseResult {
    log.debug("FDT address: {x}", .{fdt_physical_start});
    var traverser: dtb.Traverser = undefined;
    traverser.init(@ptrFromInt(fdt_physical_start)) catch @panic("invalid device tree");

    const State = enum {
        start,
        chosen,
        memory,
        plic,
        clint,
    };
    var state: State = .start;
    var initrd_start: ?u32 = null;
    var initrd_end: ?u32 = null;
    var memory_start: ?u32 = null;
    var memory_size: ?u32 = null;
    var plic_start: ?u32 = null;
    var plic_size: ?u32 = null;
    var clint_start: ?u32 = null;
    var clint_size: ?u32 = null;

    while (true) {
        const event = traverser.event() catch break;
        switch (event) {
            .BeginNode => |b| {
                if (mem.eql(u8, b, "chosen")) {
                    state = .chosen;
                } else if (mem.startsWith(u8, b, "memory")) {
                    state = .memory;
                } else if (mem.startsWith(u8, b, "plic")) {
                    state = .plic;
                } else if (mem.startsWith(u8, b, "clint")) {
                    state = .clint;
                }
            },
            .Prop => |p| {
                switch (state) {
                    .chosen => {
                        if (mem.eql(u8, p.name, "linux,initrd-start")) {
                            initrd_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                        } else if (mem.eql(u8, p.name, "linux,initrd-end")) {
                            initrd_end = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                        }
                    },
                    .memory => {
                        if (mem.eql(u8, p.name, "reg")) {
                            memory_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            memory_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .plic => {
                        if (mem.eql(u8, p.name, "reg")) {
                            plic_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            plic_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .clint => {
                        if (mem.eql(u8, p.name, "reg")) {
                            clint_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            clint_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    else => continue,
                }
            },
            .EndNode => {
                state = .start;
            },
            .End => break,
        }
    }
    if (initrd_start == null) {
        @panic("initrd start address was not found in the device tree.");
    } else if (initrd_end == null) {
        @panic("initrd end address was not found in the device tree.");
    } else if (initrd_end.? < initrd_start.?) {
        @panic("initrd end address is before start address.");
    } else if (memory_start == null) {
        @panic("memory start address was not found in the device tree.");
    } else if (memory_size == null) {
        @panic("memory size was not found in the device tree.");
    } else if (plic_start == null) {
        @panic("PLIC start address was not found in the device tree.");
    } else if (plic_size == null) {
        @panic("PLIC size was not found in the device tree.");
    } else if (clint_start == null) {
        @panic("CLINT start address was not found in the device tree.");
    } else if (clint_size == null) {
        @panic("CLINT size was not found in the device tree.");
    }
    return .{
        .fdt_size = @intCast(traverser.header.totalsize),
        .fdt_physical_end = 0,
        .initrd_physical_start = @intCast(initrd_start.?),
        .initrd_size = @intCast(initrd_end.? - initrd_start.?),
        .initrd_physical_end = @intCast(initrd_end.?),
        .ram_physical_start = @intCast(memory_start.?),
        .ram_size = @intCast(memory_size.?),
        .ram_physical_end = @intCast(memory_start.? + memory_size.?),
        .plic_physical_start = @intCast(plic_start.?),
        .plic_size = @intCast(plic_size.?),
        .plic_physical_end = @intCast(plic_start.? + plic_size.?),
        .clint_physical_start = @intCast(clint_start.?),
        .clint_size = @intCast(clint_size.?),
        .clint_physical_end = @intCast(clint_start.? + clint_size.?),
    };
}

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.err("PANIC: {s}.\n{?}", .{ msg, stack_trace });
    while (true) {
        asm volatile ("wfi");
    }
}
