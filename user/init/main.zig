const std = @import("std");
const elf = std.elf;
const tar = std.tar;
const io = std.io;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const libt = @import("libt");
const syscall = libt.syscall;
const service = libt.service;
const Handle = libt.Handle;

pub const os = libt;

const stack_size = 0x10;
const DriverMap = std.StringHashMap([]const u8);
const ServiceMap = std.AutoHashMap(u32, ServiceProvider);

const ServiceProvider = struct {
    process: Handle,
    region: Handle,
};

export fn _start() callconv(.Naked) noreturn {
    // Save FDT address.
    asm volatile ("mv s0, a0");

    // Allocate and map stack, jump to main.
    asm volatile (
        \\li a0, %[allocate_id]
        \\li a1, 0
        \\li a2, %[stack_size]
        \\li a3, %[stack_permissions]
        \\li a4, 0
        \\ecall
        \\bltz a0, 1f
        \\mv sp, %[stack_address]
        \\mul a3, a2, %[page_size]
        \\sub a3, sp, a3
        // \\li a1, 0
        \\mv a2, a0
        \\li a0, %[map_id]
        \\ecall
        \\bltz a0, 1f
        \\mv a0, s0
        \\jalr %[main]
        \\1:
        \\mv a1, a0
        \\li a0, %[exit_id]
        \\ecall
        :
        : [allocate_id] "I" (@intFromEnum(syscall.Id.region_allocate)),
          [stack_size] "I" (stack_size),
          [stack_permissions] "I" (syscall.RegionPermissions{ .read = true, .write = true }),
          [stack_address] "{t1}" (libt.address_space_end),
          [page_size] "{t2}" (mem.page_size),
          [map_id] "I" (@intFromEnum(syscall.Id.region_map)),
          [main] "{t3}" (&main),
          [exit_id] "I" (@intFromEnum(syscall.Id.exit)),
    );
}

pub fn main() usize {
    var gpa = heap.GeneralPurposeAllocator(.{
        .thread_safe = false,
        .safety = false,
    }){};
    const allocator = gpa.allocator();

    var driver_map = DriverMap.init(allocator);
    populateDriverMap(&driver_map, allocator) catch return 1;

    var service_map = ServiceMap.init(allocator);

    const serial_elf = driver_map.get("ns16550a") orelse return 2;
    _ = loadElf(serial_elf, &service_map) catch return 3;

    // const smp_test_elf = driver_map.get("smp-test") orelse return 4;
    // _ = loadElf(smp_test_elf, &service_map) catch return 5;

    const virtio_blk_elf = driver_map.get("virtio-blk") orelse return 4;
    _ = loadElf(virtio_blk_elf, &service_map) catch return 5;

    const file_system_elf = driver_map.get("file-system") orelse return 6;
    _ = loadElf(file_system_elf, &service_map) catch return 7;

    const shell_elf = driver_map.get("shell") orelse return 8;
    _ = loadElf(shell_elf, &service_map) catch return 9;

    libt.sleep(math.maxInt(usize)) catch unreachable;
    unreachable;
}

fn populateDriverMap(driver_map: *DriverMap, allocator: Allocator) !void {
    const driver_archive = @embedFile("driver_archive.tar");

    var stream = io.fixedBufferStream(driver_archive);
    var file_name_buffer: [32]u8 = undefined;
    var link_name_buffer: [32]u8 = undefined;
    var it = tar.iterator(stream.reader(), .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    while (try it.next()) |file| {
        const file_data = driver_archive[stream.pos..][0..file.size];
        const file_name = try allocator.dupe(u8, file.name);
        try driver_map.put(file_name, file_data);
    }
}

fn loadElf(elf_bytes: []const u8, service_map: *ServiceMap) !Handle {
    var stream = io.fixedBufferStream(elf_bytes);
    const header = try elf.Header.read(&stream);
    if (header.machine != .RISCV)
        return error.InvalidExecutable;
    if (!header.is_64)
        return error.InvalidExecutable;

    const process = try syscall.processAllocate(.self);

    var it = header.program_header_iterator(&stream);
    while (try it.next()) |program_header| {
        if (program_header.p_type == elf.PT_LOAD) {
            try handleLoadSegment(process, program_header, elf_bytes);
        } else if (program_header.p_type >= elf.PT_LOOS and program_header.p_type <= elf.PT_HIOS) {
            try handleServiceSegment(process, program_header, service_map);
        }
    }

    // Allocate a stack for the process.
    const region = try syscall.regionAllocate(process, stack_size, .{ .read = true, .write = true }, null);
    const stack_end: [*]align(mem.page_size) u8 = @ptrFromInt(libt.address_space_end);
    const stack_start: [*]align(mem.page_size) u8 = stack_end - stack_size * mem.page_size;
    _ = try syscall.regionMap(process, region, stack_start);

    return syscall.threadAllocate(.self, process, @ptrFromInt(header.entry), stack_end, 0, 0, 0);
}

fn handleLoadSegment(process: Handle, header: elf.Elf64_Phdr, elf_bytes: []const u8) !void {
    const start_address = mem.alignBackward(usize, header.p_vaddr, mem.page_size);
    const end_address = mem.alignForward(usize, header.p_vaddr + header.p_memsz, mem.page_size);
    const size = (end_address - start_address) / mem.page_size;
    const permissions: syscall.RegionPermissions = .{
        .read = header.p_flags & elf.PF_R != 0,
        .write = header.p_flags & elf.PF_W != 0,
        .execute = header.p_flags & elf.PF_X != 0,
    };

    const region = try syscall.regionAllocate(process, size, permissions, null);
    _ = try syscall.regionMap(process, region, @ptrFromInt(start_address));

    const source = elf_bytes.ptr + header.p_offset;
    const offset = header.p_vaddr % mem.page_size;
    try syscall.regionWrite(process, region, source, offset, header.p_filesz);
}

fn handleServiceSegment(process: Handle, header: elf.Elf64_Phdr, service_map: *ServiceMap) !void {
    const start_address = mem.alignBackward(usize, header.p_vaddr, mem.page_size);
    const end_address = mem.alignForward(usize, header.p_vaddr + header.p_memsz, mem.page_size);
    const size = (end_address - start_address) / mem.page_size;
    const permissions: syscall.RegionPermissions = .{
        .read = header.p_flags & elf.PF_R != 0,
        .write = header.p_flags & elf.PF_W != 0,
        .execute = header.p_flags & elf.PF_X != 0,
    };

    if (header.p_flags & service.Flags.mask_p != 0) {
        const region = try syscall.regionAllocate(process, size, permissions, null);
        _ = try syscall.regionMap(process, region, @ptrFromInt(start_address));
        try service_map.put(header.p_type, .{ .process = process, .region = region });
    } else {
        const service_provider = service_map.get(header.p_type) orelse return error.ServiceMissing;
        const region = try syscall.regionShare(service_provider.process, service_provider.region, process, permissions);
        _ = try syscall.regionMap(process, region, @ptrFromInt(start_address));
    }
}
