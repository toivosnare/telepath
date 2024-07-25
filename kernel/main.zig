const std = @import("std");
const mm = @import("mm.zig");
const proc = @import("proc.zig");
const trap = @import("trap.zig");
const dtb = @import("dtb");
const libt = @import("libt");
const sbi = @import("sbi");
const log = std.log;
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;
const Region = mm.Region;
const PhysicalAddress = mm.PhysicalAddress;
const UserVirtualAddress = mm.UserVirtualAddress;
const KernelVirtualAddress = mm.KernelVirtualAddress;
const Page = mm.Page;
const ConstPagePtr = mm.ConstPagePtr;
const ConstPageSlice = mm.ConstPageSlice;
const ConstPageFramePtr = mm.ConstPageFramePtr;
const PageFrameSlice = mm.PageFrameSlice;
const ConstPageFrameSlice = mm.ConstPageSlice;
const Process = proc.Process;
const tix = libt.tix;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

extern const kernel_linker_start: anyopaque;
extern const kernel_linker_end: anyopaque;

const HartId = usize;
var hart_id_array: [mm.MAX_HARTS]HartId = undefined;
var hart_ids: []HartId = undefined;

export fn bootHartMain(boot_hart_id: usize, fdt_physical_start: PhysicalAddress, kernel_physical_start: PhysicalAddress) noreturn {
    trap.init();
    log.info("Boot hart with id {} booting..", .{boot_hart_id});
    log.debug("fdt_physical_start={x}", .{fdt_physical_start});
    log.debug("kernel_physical_start={x}", .{kernel_physical_start});

    hart_id_array[0] = boot_hart_id;
    const pr = parseFdt(fdt_physical_start);
    log.debug("harts: {any}", .{hart_ids});
    log.debug("fdt: {any}", .{pr});
    for (hart_ids[1..], 2..) |secondary_hart_id, i|
        sbi.hsm.hartStart(secondary_hart_id, @intFromPtr(&secondaryHartEntry), i) catch @panic("hartStart");

    const kernel_size = @intFromPtr(&kernel_linker_end) - @intFromPtr(&kernel_linker_start);
    const kernel_physical_end = kernel_physical_start + kernel_size;
    const kernel_size_in_pages = math.divCeil(usize, kernel_size, @sizeOf(Page)) catch unreachable;
    const heap_physical_start = mem.alignForward(PhysicalAddress, kernel_physical_end, @sizeOf(Page));
    const heap_physical_end = mem.alignBackward(PhysicalAddress, pr.ram_physical_end, @sizeOf(Page));
    assert(heap_physical_start < heap_physical_end);

    var kernel_physical_slice: ConstPageFrameSlice = undefined;
    kernel_physical_slice.ptr = @ptrFromInt(kernel_physical_start);
    kernel_physical_slice.len = kernel_size_in_pages;

    var heap_physical_slice: PageFrameSlice = undefined;
    heap_physical_slice.ptr = @ptrFromInt(heap_physical_start);
    heap_physical_slice.len = (heap_physical_end - heap_physical_start) / @sizeOf(Page);

    var fdt_physical_slice: PageFrameSlice = undefined;
    fdt_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, fdt_physical_start, @sizeOf(Page)));
    fdt_physical_slice.len = math.divCeil(usize, pr.fdt_size, @sizeOf(Page)) catch unreachable;

    var initrd_physical_slice: PageFrameSlice = undefined;
    initrd_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, pr.initrd_physical_start, @sizeOf(Page)));
    initrd_physical_slice.len = math.divCeil(usize, pr.initrd_size, @sizeOf(Page)) catch unreachable;

    var kernel_virtual_slice: ConstPageSlice = undefined;
    kernel_virtual_slice.ptr = @ptrFromInt(mm.kernel_virtual_start);
    kernel_virtual_slice.len = kernel_size_in_pages;
    mm.kernel_offset = mm.kernel_virtual_start -% kernel_physical_start;

    var logical_mapping_virtual_slice: ConstPageSlice = undefined;
    logical_mapping_virtual_slice.ptr = @ptrFromInt(mm.logical_mapping_virtual_start);
    logical_mapping_virtual_slice.len = heap_physical_slice.len;
    mm.logical_mapping_offset = mm.logical_mapping_virtual_start -% heap_physical_start;

    mm.init(heap_physical_slice, &.{ fdt_physical_slice, initrd_physical_slice });
    proc.init();

    const init_process = proc.allocate() catch unreachable;
    init_process.page_table = @ptrCast(mm.page_allocator.allocate(0) catch @panic("OOM"));
    @memset(mem.asBytes(init_process.page_table), 0);

    const trampoline_page: ConstPageFramePtr = @ptrCast(&trampoline);
    mm.mapPage(init_process.page_table, trampoline_page, trampoline_page, .{ .valid = true, .readable = true, .executable = true });
    mm.mapRange(init_process.page_table, logical_mapping_virtual_slice, heap_physical_slice, .{ .valid = true, .readable = true, .writable = true, .global = true });
    mm.mapRange(init_process.page_table, kernel_virtual_slice, kernel_physical_slice, .{ .valid = true, .readable = true, .writable = true, .executable = true, .global = true });

    const tix_header: *tix.Header = @ptrFromInt(pr.initrd_physical_start);
    if (!mem.eql(u8, &tix_header.magic, &tix.Header.MAGIC))
        @panic("Invalid TIX magic.");
    init_process.register_file.pc = tix_header.entry_point;

    var region_headers: []tix.RegionHeader = undefined;
    region_headers.ptr = @ptrFromInt(pr.initrd_physical_start + @sizeOf(tix.Header));
    region_headers.len = tix_header.region_amount;

    for (region_headers) |rh| {
        log.debug("region header: {}", .{rh});
        const region_size_in_pages = math.divCeil(usize, rh.size, @sizeOf(Page)) catch unreachable;
        const region_entry = init_process.allocateRegion(region_size_in_pages, .{
            .readable = rh.readable,
            .writable = rh.writable,
            .executable = rh.executable,
        }) catch @panic("allocateRegion");
        const aligned_load_address = mem.alignBackward(UserVirtualAddress, rh.load_address, @sizeOf(Page));
        _ = init_process.mapRegionEntry(region_entry, aligned_load_address) catch @panic("mapRegionEntry");

        const page_offset = rh.load_address % @sizeOf(Page);
        const dest = mem.asBytes(region_entry.region.?.allocation).ptr + page_offset;

        var source: []const u8 = undefined;
        source.ptr = @ptrFromInt(pr.initrd_physical_start + rh.offset);
        source.len = rh.size;

        @memcpy(dest, source);
        log.debug("copied {} bytes from {*} to {*}", .{ rh.size, source.ptr, dest });
    }
    // mm.page_allocator.freeSlice(initrd_physical_slice);

    const v: ConstPagePtr = @ptrFromInt(mem.alignBackward(UserVirtualAddress, init_process.register_file.pc, @sizeOf(Page)));
    const entry_region = init_process.region_entries[1].region.?;
    const p: ConstPagePtr = @ptrCast(entry_region.allocation.ptr);
    mm.mapPage(init_process.page_table, v, p, .{ .valid = true, .readable = true, .writable = true, .executable = true, .user = true });

    const fdt_region = Region.findFree() catch @panic("findFree");
    fdt_region.ref_count = 1;
    // fdt_region.allocation = _;
    fdt_region.size = fdt_physical_slice.len;
    const fdt_region_entry = init_process.receiveRegion(fdt_region, .{ .readable = true }) catch @panic("receiveRegion");
    const fdt_page_address = init_process.mapRegionEntry(fdt_region_entry, null) catch @panic("mapRegionEntry");
    const fdt_page_offset = fdt_physical_start % @sizeOf(Page);
    const fdt_virtual_start = fdt_page_address + fdt_page_offset;
    init_process.register_file.a0 = fdt_virtual_start;

    const satp = (8 << 60) | @intFromPtr(init_process.page_table) >> 12;
    log.debug("satp: {x}", .{satp});
    trampoline(satp, 0, mm.kernel_offset);
}

extern fn secondaryHartEntry(hart_id: usize, x: usize) callconv(.Naked) noreturn;

export fn secondaryHartMain(hart_id: usize) noreturn {
    log.info("Secondary hart with id {} booting.", .{hart_id});
    while (true) {
        asm volatile ("wfi");
    }
}
extern fn trampoline(satp: usize, hart_index: usize, kernel_offset: usize) align(@sizeOf(Page)) noreturn;

export fn main() noreturn {
    mm.address_translation_on = true;
    writer.writeFn = writeFn;
    trap.onAddressTranslationEnabled();
    mm.page_allocator.onAddressTranslationEnabled();
    const init_process = proc.onAddressTranslationEnabled();

    log.info("Address translation enabled for boot hart.", .{});
    returnToUserspace(init_process.id, &init_process.register_file);
}

extern fn returnToUserspace(id: Process.Id, register_file: *const Process.RegisterFile) noreturn;

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
    var traverser: dtb.Traverser = undefined;
    traverser.init(@ptrFromInt(fdt_physical_start)) catch @panic("invalid device tree");

    const State = enum {
        start,
        chosen,
        memory,
        plic,
        clint,
        hart,
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
    var hart_count: usize = 1;

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
                } else if (mem.startsWith(u8, b, "cpu@")) {
                    state = .hart;
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
                    .hart => {
                        if (mem.eql(u8, p.name, "reg")) {
                            const hart_id = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                            if (hart_id != hart_id_array[0]) {
                                hart_id_array[hart_count] = hart_id;
                                hart_count += 1;
                            }
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
    hart_ids = hart_id_array[0..hart_count];
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

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.err("PANIC: {s}.", .{msg});
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ if (scope == std.log.default_log_scope) "" else "(" ++ @tagName(scope) ++ ") ";
    writer.print(prefix ++ format ++ "\n", args) catch return;
}

var writer: std.io.AnyWriter = .{ .context = undefined, .writeFn = writeFn };

fn writeFn(_: *const anyopaque, bytes: []const u8) !usize {
    var ptr = @intFromPtr(bytes.ptr);
    if (mm.address_translation_on)
        ptr = mm.physicalFromKernelVirtual(ptr);
    for (bytes) |b| {
        if (sbi.legacy.consolePutChar(b) != .SUCCESS) @panic("consolePutChar");
    }
    return bytes.len;
}
