const std = @import("std");
const atomic = std.atomic;
const log = std.log.scoped(.main);
const math = std.math;
const assert = std.debug.assert;
const mem = std.mem;
const sbi = @import("sbi");
const libt = @import("libt");
const tix = libt.tix;
const Spinlock = libt.sync.Spinlock;
const riscv = @import("riscv.zig");
const fdt = @import("fdt.zig");
const trap = @import("trap.zig");
const mm = @import("mm.zig");
const PhysicalAddress = mm.PhysicalAddress;
const UserVirtualAddress = mm.UserVirtualAddress;
const Page = mm.Page;
const PageSlice = mm.PageSlice;
const ConstPageFramePtr = mm.ConstPageFramePtr;
const PageFrameSlice = mm.PageFrameSlice;
const PhysicalPageNumber = mm.PhysicalPageNumber;
const proc = @import("proc.zig");
const Hart = proc.Hart;
const Capability = proc.Capability;

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

extern const linker_text: anyopaque;
extern const linker_rodata: anyopaque;
extern const linker_data: anyopaque;
extern const linker_bss: anyopaque;
extern const linker_plic: anyopaque;
extern const linker_end: anyopaque;

export fn bootHartMain(boot_hart_id: Hart.Id, fdt_physical_start: PhysicalAddress, kernel_physical_start: PhysicalAddress) noreturn {
    trap.init();

    log.info(
        \\
        \\
        \\  ████████╗███████╗██╗     ███████╗██████╗  █████╗ ████████╗██╗  ██╗
        \\  ╚══██╔══╝██╔════╝██║     ██╔════╝██╔══██╗██╔══██╗╚══██╔══╝██║  ██║
        \\     ██║   █████╗  ██║     █████╗  ██████╔╝███████║   ██║   ███████║
        \\     ██║   ██╔══╝  ██║     ██╔══╝  ██╔═══╝ ██╔══██║   ██║   ██╔══██║
        \\     ██║   ███████╗███████╗███████╗██║     ██║  ██║   ██║   ██║  ██║
        \\     ╚═╝   ╚══════╝╚══════╝╚══════╝╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝
        \\
    , .{});

    log.info("Booting kernel on boot hart id={d}", .{boot_hart_id});
    proc.hart_array[0].id = boot_hart_id;

    log.info("Loading FDT from physical address 0x{x}", .{fdt_physical_start});
    const pr = fdt.parse(fdt_physical_start);
    proc.ticks_per_us = pr.timebase_frequency / std.time.us_per_s;
    mm.ram_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, pr.ram_physical_start, @sizeOf(Page)));
    mm.ram_physical_slice.len = math.divCeil(usize, pr.ram_size, @sizeOf(Page)) catch unreachable;

    const text_exe_offset = @intFromPtr(&linker_text) - @intFromPtr(&linker_text);
    const rodata_exe_offset = @intFromPtr(&linker_rodata) - @intFromPtr(&linker_text);
    const data_exe_offset = @intFromPtr(&linker_data) - @intFromPtr(&linker_text);
    const bss_exe_offset = @intFromPtr(&linker_bss) - @intFromPtr(&linker_text);
    const plic_exe_offset = @intFromPtr(&linker_plic) - @intFromPtr(&linker_text);
    mm.kernel_size = @intFromPtr(&linker_end) - @intFromPtr(&linker_text);

    assert(text_exe_offset % @sizeOf(Page) == 0);
    assert(rodata_exe_offset % @sizeOf(Page) == 0);
    assert(data_exe_offset % @sizeOf(Page) == 0);
    assert(plic_exe_offset % @sizeOf(Page) == 0);
    assert(mm.kernel_size % @sizeOf(Page) == 0);

    const text_size = rodata_exe_offset - text_exe_offset;
    const rodata_size = data_exe_offset - rodata_exe_offset;
    const data_size = bss_exe_offset - data_exe_offset;
    const bss_size = plic_exe_offset - bss_exe_offset;
    const plic_size = mm.kernel_size - plic_exe_offset;
    const data_and_bss_size = data_size + bss_size;

    assert(text_size % @sizeOf(Page) == 0);
    assert(rodata_size % @sizeOf(Page) == 0);
    assert(plic_size % @sizeOf(Page) == 0);
    assert(data_and_bss_size % @sizeOf(Page) == 0);

    var text_slice: PageSlice = undefined;
    text_slice.ptr = @ptrFromInt(mm.kernel_start + text_exe_offset);
    text_slice.len = text_size / @sizeOf(Page);
    var text_physical_slice: PageFrameSlice = undefined;
    text_physical_slice.ptr = @ptrFromInt(kernel_physical_start + text_exe_offset);
    text_physical_slice.len = text_slice.len;

    var rodata_slice: PageSlice = undefined;
    rodata_slice.ptr = @ptrFromInt(mm.kernel_start + rodata_exe_offset);
    rodata_slice.len = rodata_size / @sizeOf(Page);
    var rodata_physical_slice: PageFrameSlice = undefined;
    rodata_physical_slice.ptr = @ptrFromInt(kernel_physical_start + rodata_exe_offset);
    rodata_physical_slice.len = rodata_slice.len;

    var data_and_bss_slice: PageSlice = undefined;
    data_and_bss_slice.ptr = @ptrFromInt(mm.kernel_start + data_exe_offset);
    data_and_bss_slice.len = data_and_bss_size / @sizeOf(Page);
    var data_and_bss_physical_slice: PageFrameSlice = undefined;
    data_and_bss_physical_slice.ptr = @ptrFromInt(kernel_physical_start + data_exe_offset);
    data_and_bss_physical_slice.len = data_and_bss_slice.len;

    var plic_slice: PageSlice = undefined;
    plic_slice.ptr = @ptrFromInt(mm.kernel_start + plic_exe_offset);
    plic_slice.len = plic_size / @sizeOf(Page);
    var plic_physical_slice: PageFrameSlice = undefined;
    plic_physical_slice.ptr = @ptrFromInt(pr.plic_physical_start);
    plic_physical_slice.len = plic_slice.len;

    const heap_physical_start = kernel_physical_start + plic_exe_offset;
    const heap_physical_end = mem.alignBackward(PhysicalAddress, pr.ram_physical_end, @sizeOf(Page));
    assert(heap_physical_start < heap_physical_end);
    mm.logical_size = (heap_physical_end - heap_physical_start) / @sizeOf(Page);

    var logical_slice: PageSlice = undefined;
    logical_slice.ptr = @ptrFromInt(mm.logical_start);
    logical_slice.len = mm.logical_size;
    var heap_physical_slice: PageFrameSlice = undefined;
    heap_physical_slice.ptr = @ptrFromInt(heap_physical_start);
    heap_physical_slice.len = mm.logical_size;

    var tix_physical_slice: PageFrameSlice = undefined;
    tix_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, pr.initrd_physical_start, @sizeOf(Page)));
    tix_physical_slice.len = math.divCeil(usize, pr.initrd_size, @sizeOf(Page)) catch unreachable;

    var fdt_physical_slice: PageFrameSlice = undefined;
    fdt_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, fdt_physical_start, @sizeOf(Page)));
    fdt_physical_slice.len = math.divCeil(usize, pr.fdt_size, @sizeOf(Page)) catch unreachable;

    var tix_allocations: PageSlice = undefined;
    var fdt_allocations: PageSlice = undefined;
    mm.init(heap_physical_slice, tix_physical_slice, fdt_physical_slice, &tix_allocations, &fdt_allocations);

    const init_process = proc.init() catch @panic("OOM");
    const trampoline_page: ConstPageFramePtr = @ptrCast(&trampoline);
    init_process.page_table.map(trampoline_page, trampoline_page, .{ .valid = true, .readable = true, .executable = true }) catch @panic("OOM");
    init_process.page_table.mapRange(logical_slice, heap_physical_slice, .{ .valid = true, .readable = true, .writable = true, .global = true }) catch @panic("OOM");
    init_process.page_table.mapRange(text_slice, text_physical_slice, .{ .valid = true, .executable = true, .global = true }) catch @panic("OOM");
    init_process.page_table.mapRange(rodata_slice, rodata_physical_slice, .{ .valid = true, .readable = true, .global = true }) catch @panic("OOM");
    init_process.page_table.mapRange(data_and_bss_slice, data_and_bss_physical_slice, .{ .valid = true, .readable = true, .writable = true, .global = true }) catch @panic("OOM");
    init_process.page_table.mapRange(plic_slice, plic_physical_slice, .{ .valid = true, .readable = true, .writable = true, .global = true }) catch @panic("OOM");

    log.info("Loading TIX from physical address 0x{x}", .{pr.initrd_physical_start});
    const tix_header: *tix.Header = @ptrFromInt(pr.initrd_physical_start);
    if (!mem.eql(u8, &tix_header.magic, &tix.Header.MAGIC))
        @panic("invalid TIX magic");
    const entry_point = tix_header.entry_point;

    var region_headers: []tix.RegionHeader = undefined;
    region_headers.ptr = @ptrFromInt(pr.initrd_physical_start + @sizeOf(tix.Header));
    region_headers.len = tix_header.region_amount;

    for (region_headers) |rh| {
        const region_size_in_pages = math.divCeil(usize, rh.memory_size, @sizeOf(Page)) catch unreachable;
        const region_handle = init_process.allocateRegion(region_size_in_pages, .{
            .read = rh.readable,
            .write = rh.writable,
            .execute = rh.executable,
        }, 0) catch @panic("allocateRegion");
        const aligned_load_address = mem.alignBackward(UserVirtualAddress, rh.load_address, @sizeOf(Page));
        _ = init_process.mapRegion(region_handle, aligned_load_address) catch @panic("mapRegion");

        const region_capability = Capability.get(region_handle, init_process) catch unreachable;
        const region = region_capability.object.region;
        const page_offset = rh.load_address % @sizeOf(Page);
        const dest = mem.asBytes(region.allocation).ptr + page_offset;

        var source: []const u8 = undefined;
        source.ptr = @ptrFromInt(pr.initrd_physical_start + rh.offset);
        source.len = rh.file_size;

        @memcpy(dest, source);
    }

    // Free temporary TIX allocations.
    var start: usize = 0;
    var end: usize = mm.page_allocator.max_order_pages;
    while (end <= tix_allocations.len) {
        const slice = tix_allocations[start..end];
        mm.page_allocator.free(slice);
        start = end;
        end += mm.page_allocator.max_order_pages;
    }

    // Allocate and map region for the FDT for init process.
    // The FDT is copied to make sure it is aligned to a page boundary (also everything was easier to implement this way).
    const fdt_region_handle = init_process.allocateRegion(fdt_physical_slice.len, .{ .read = true }, 0) catch @panic("OOM");
    const fdt_address = init_process.mapRegion(fdt_region_handle, 0) catch @panic("mapRegion");
    const fdt_region_capability = Capability.get(fdt_region_handle, init_process) catch unreachable;
    const fdt_region = fdt_region_capability.object.region;

    const dest: [*]u8 = @ptrCast(fdt_region.allocation.ptr);
    var source: []u8 = undefined;
    source.ptr = @ptrFromInt(fdt_physical_start);
    source.len = pr.fdt_size;
    @memcpy(dest, source);

    // Free temporary FDT allocations.
    start = 0;
    end = mm.page_allocator.max_order_pages;
    while (end <= fdt_allocations.len) {
        const slice = fdt_allocations[start..end];
        mm.page_allocator.free(slice);
        start = end;
        end += mm.page_allocator.max_order_pages;
    }

    _ = init_process.allocateThread(.self, entry_point, 0, fdt_address, 0) catch @panic("OOM");

    const satp: riscv.satp.Type = .{
        .ppn = @bitCast(PhysicalPageNumber.fromPageTable(init_process.page_table)),
        .asid = 0,
        .mode = .sv39,
    };
    mm.logical_offset = mm.logical_start -% heap_physical_start;
    mm.kernel_offset = mm.kernel_start -% kernel_physical_start;
    trampoline(0, satp, mm.kernel_offset);
}

extern fn trampoline(hart_index: Hart.Index, satp: riscv.satp.Type, kernel_offset: usize) align(@sizeOf(Page)) noreturn;

extern fn secondaryHartEntry(hart_id: Hart.Id, hart_index: Hart.Index) callconv(.Naked) noreturn;

export fn secondaryHartMain(hart_index: Hart.Index) noreturn {
    trap.init();
    const init_process = &proc.process_table[0].process;
    const satp: riscv.satp.Type = .{
        .ppn = @bitCast(PhysicalPageNumber.fromPageTable(init_process.page_table)),
        .asid = 0,
        .mode = .sv39,
    };
    trampoline(hart_index, satp, mm.kernel_offset);
}

var harts_ready: atomic.Value(usize) = atomic.Value(usize).init(0);

export fn main(hart_index: Hart.Index) noreturn {
    if (hart_index == 0) {
        writer.writeFn = writeFn;
        proc.onAddressTranslationEnabled();
        trap.onAddressTranslationEnabled(hart_index);
        mm.page_allocator.onAddressTranslationEnabled();

        log.info("Address translation enabled for boot hart. Bringing up other harts", .{});
        for (proc.harts[1..], 1..) |*secondary_hart, i|
            sbi.hsm.hartStart(secondary_hart.id, @intFromPtr(&secondaryHartEntry), i) catch @panic("hartStart");

        while (harts_ready.load(.monotonic) < proc.harts.len - 1) {}

        const trampoline_page: ConstPageFramePtr = @ptrCast(&trampoline);
        const init_process = &proc.process_table[0].process;
        init_process.page_table.unmap(trampoline_page);

        log.info("All harts ready", .{});
        _ = harts_ready.fetchAdd(1, .monotonic);
    } else {
        trap.onAddressTranslationEnabled(hart_index);
        log.info("Secondary hart index={d} id={d} ready", .{ hart_index, proc.harts[hart_index].id });
        _ = harts_ready.fetchAdd(1, .monotonic);
        while (harts_ready.load(.monotonic) < proc.harts.len) {}
    }
    proc.scheduler.scheduleNext(null, hart_index);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.err("PANIC: {s}", .{msg});
    while (true) {
        asm volatile ("wfi");
    }
}

var log_lock: Spinlock = .{};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_lock.lock();
    defer log_lock.unlock();
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ if (scope == std.log.default_log_scope) "" else "(" ++ @tagName(scope) ++ ") ";
    writer.print(prefix ++ format ++ "\n", args) catch return;
}

var writer: std.io.AnyWriter = .{ .context = undefined, .writeFn = writeFn };

fn writeFn(_: *const anyopaque, bytes: []const u8) !usize {
    for (bytes) |b| {
        if (sbi.legacy.consolePutChar(b) != .SUCCESS) @panic("consolePutChar");
    }
    return bytes.len;
}
