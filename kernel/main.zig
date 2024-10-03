const std = @import("std");
const mm = @import("mm.zig");
const proc = @import("proc.zig");
const trap = @import("trap.zig");
const fdt = @import("fdt.zig");
const riscv = @import("riscv.zig");
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
const PageSlice = mm.PageSlice;
const ConstPageSlice = mm.ConstPageSlice;
const ConstPageFramePtr = mm.ConstPageFramePtr;
const PageFrameSlice = mm.PageFrameSlice;
const ConstPageFrameSlice = mm.ConstPageSlice;
const PhysicalPageNumber = mm.PhysicalPageNumber;
const Process = proc.Process;
const Hart = proc.Hart;
const tix = libt.tix;
const Spinlock = libt.sync.Spinlock;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

extern const kernel_linker_start: anyopaque;
extern const kernel_linker_end: anyopaque;

export fn bootHartMain(boot_hart_id: Hart.Id, fdt_physical_start: PhysicalAddress, kernel_physical_start: PhysicalAddress) noreturn {
    trap.init();
    log.info("Boot hart with id {} booting..", .{boot_hart_id});
    log.debug("fdt_physical_start={x}", .{fdt_physical_start});
    log.debug("kernel_physical_start={x}", .{kernel_physical_start});

    proc.hart_array[0].id = boot_hart_id;
    const pr = fdt.parse(fdt_physical_start);
    log.debug("harts: {any}", .{proc.harts});
    log.debug("fdt: {any}", .{pr});
    for (proc.harts[1..], 2..) |*secondary_hart, i|
        sbi.hsm.hartStart(secondary_hart.id, @intFromPtr(&secondaryHartEntry), i) catch @panic("hartStart");

    mm.ram_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, pr.ram_physical_start, @sizeOf(Page)));
    mm.ram_physical_slice.len = math.divCeil(usize, pr.ram_size, @sizeOf(Page)) catch unreachable;

    const kernel_size = @intFromPtr(&kernel_linker_end) - @intFromPtr(&kernel_linker_start);
    const kernel_physical_end = kernel_physical_start + kernel_size;
    mm.kernel_size = math.divCeil(usize, kernel_size, @sizeOf(Page)) catch unreachable;
    const heap_physical_start = mem.alignForward(PhysicalAddress, kernel_physical_end, @sizeOf(Page));
    const heap_physical_end = mem.alignBackward(PhysicalAddress, pr.ram_physical_end, @sizeOf(Page));
    mm.logical_size = (heap_physical_end - heap_physical_start) / @sizeOf(Page);
    assert(heap_physical_start < heap_physical_end);

    var kernel_physical_slice: ConstPageFrameSlice = undefined;
    kernel_physical_slice.ptr = @ptrFromInt(kernel_physical_start);
    kernel_physical_slice.len = mm.kernel_size;

    var heap_physical_slice: PageFrameSlice = undefined;
    heap_physical_slice.ptr = @ptrFromInt(heap_physical_start);
    heap_physical_slice.len = mm.logical_size;

    var tix_physical_slice: PageFrameSlice = undefined;
    tix_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, pr.initrd_physical_start, @sizeOf(Page)));
    tix_physical_slice.len = math.divCeil(usize, pr.initrd_size, @sizeOf(Page)) catch unreachable;

    var fdt_physical_slice: PageFrameSlice = undefined;
    fdt_physical_slice.ptr = @ptrFromInt(mem.alignBackward(PhysicalAddress, fdt_physical_start, @sizeOf(Page)));
    fdt_physical_slice.len = math.divCeil(usize, pr.fdt_size, @sizeOf(Page)) catch unreachable;

    var kernel_slice: ConstPageSlice = undefined;
    kernel_slice.ptr = @ptrFromInt(mm.kernel_start);
    kernel_slice.len = mm.kernel_size;

    var logical_slice: ConstPageSlice = undefined;
    logical_slice.ptr = @ptrFromInt(mm.logical_start);
    logical_slice.len = mm.logical_size;

    var tix_allocations: PageSlice = undefined;
    var fdt_allocations: PageSlice = undefined;
    mm.init(heap_physical_slice, tix_physical_slice, fdt_physical_slice, &tix_allocations, &fdt_allocations);

    const init_process = proc.init();
    const trampoline_page: ConstPageFramePtr = @ptrCast(&trampoline);
    init_process.page_table.map(trampoline_page, trampoline_page, .{ .valid = true, .readable = true, .executable = true }) catch @panic("OOM");
    init_process.page_table.mapRange(logical_slice, heap_physical_slice, .{ .valid = true, .readable = true, .writable = true, .global = true }) catch @panic("OOM");
    // TODO: Map different parts of the kernel with different permissions.
    init_process.page_table.mapRange(kernel_slice, kernel_physical_slice, .{ .valid = true, .readable = true, .writable = true, .executable = true, .global = true }) catch @panic("OOM");

    const tix_header: *tix.Header = @ptrFromInt(pr.initrd_physical_start);
    if (!mem.eql(u8, &tix_header.magic, &tix.Header.MAGIC))
        @panic("Invalid TIX magic.");
    init_process.context.pc = tix_header.entry_point;

    var region_headers: []tix.RegionHeader = undefined;
    region_headers.ptr = @ptrFromInt(pr.initrd_physical_start + @sizeOf(tix.Header));
    region_headers.len = tix_header.region_amount;

    for (region_headers) |rh| {
        log.debug("region header: {}", .{rh});
        const region_size_in_pages = math.divCeil(usize, rh.memory_size, @sizeOf(Page)) catch unreachable;
        const region_entry = init_process.allocateRegion(region_size_in_pages, .{
            .readable = rh.readable,
            .writable = rh.writable,
            .executable = rh.executable,
        }, 0) catch @panic("allocateRegion");
        const aligned_load_address = mem.alignBackward(UserVirtualAddress, rh.load_address, @sizeOf(Page));
        _ = init_process.mapRegionEntry(region_entry, aligned_load_address) catch @panic("mapRegionEntry");

        const page_offset = rh.load_address % @sizeOf(Page);
        const dest = mem.asBytes(region_entry.region.?.allocation).ptr + page_offset;

        var source: []const u8 = undefined;
        source.ptr = @ptrFromInt(pr.initrd_physical_start + rh.offset);
        source.len = rh.file_size;

        @memcpy(dest, source);
        log.debug("copied {} bytes from {*} to {*}", .{ rh.file_size, source.ptr, dest });
    }
    var start: usize = 0;
    var end: usize = mm.page_allocator.max_order_pages;
    while (end <= tix_allocations.len) {
        const slice = tix_allocations[start..end];
        mm.page_allocator.free(slice);
        start = end;
        end += mm.page_allocator.max_order_pages;
    }

    const fdt_region_entry = init_process.allocateRegion(fdt_physical_slice.len, .{ .readable = true }, 0) catch @panic("OOM");
    const fdt_address = init_process.mapRegionEntry(fdt_region_entry, 0) catch @panic("mapRegionEntry");
    init_process.context.a0 = fdt_address;

    const dest: [*]u8 = @ptrCast(fdt_region_entry.region.?.allocation.ptr);
    var source: []u8 = undefined;
    source.ptr = @ptrFromInt(fdt_physical_start);
    source.len = pr.fdt_size;
    @memcpy(dest, source);

    start = 0;
    end = mm.page_allocator.max_order_pages;
    while (end <= fdt_allocations.len) {
        const slice = fdt_allocations[start..end];
        mm.page_allocator.free(slice);
        start = end;
        end += mm.page_allocator.max_order_pages;
    }

    const satp: riscv.satp.Type = .{
        .ppn = @bitCast(PhysicalPageNumber.fromPageTable(init_process.page_table)),
        .asid = 0,
        .mode = .sv39,
    };
    mm.logical_offset = mm.logical_start -% heap_physical_start;
    mm.kernel_offset = mm.kernel_start -% kernel_physical_start;
    trampoline(0, satp, mm.kernel_offset);
}

extern fn secondaryHartEntry(hart_id: Hart.Id, x: usize) callconv(.Naked) noreturn;

export fn secondaryHartMain(hart_id: Hart.Id) noreturn {
    log.info("Secondary hart with id {} booting.", .{hart_id});
    while (true) {
        asm volatile ("wfi");
    }
}
extern fn trampoline(hart_index: Hart.Index, satp: riscv.satp.Type, kernel_offset: usize) align(@sizeOf(Page)) noreturn;

export fn main(hart_index: Hart.Index) noreturn {
    writer.writeFn = writeFn;
    trap.onAddressTranslationEnabled();
    mm.page_allocator.onAddressTranslationEnabled();
    proc.onAddressTranslationEnabled();
    log.info("Address translation enabled for boot hart.", .{});
    proc.scheduleNext(null, hart_index);
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
var writer_lock: Spinlock = .{};

fn writeFn(_: *const anyopaque, bytes: []const u8) !usize {
    writer_lock.lock();
    defer writer_lock.unlock();

    for (bytes) |b| {
        if (sbi.legacy.consolePutChar(b) != .SUCCESS) @panic("consolePutChar");
    }
    return bytes.len;
}
