const std = @import("std");
const elf = std.elf;
const tar = std.tar;
const io = std.io;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const syscall = libt.syscall;

pub const os = libt;

const stack_size = 0x10;
const DriverMap = std.StringHashMap([]const u8);

export fn _start() callconv(.Naked) noreturn {
    // Save FDT address.
    asm volatile ("mv s0, a0");

    // Allocate and map stack, jump to main.
    asm volatile (
        \\li a0, %[allocate_id]
        \\li a1, %[stack_size]
        \\li a2, %[stack_permissions]
        \\li a3, 0
        \\ecall
        \\bltz a0, 1f
        \\mv sp, %[stack_address]
        \\mul a2, a1, %[page_size]
        \\sub a2, sp, a2
        \\mv a1, a0
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
        : [allocate_id] "I" (@intFromEnum(syscall.Id.allocate)),
          [stack_size] "I" (stack_size),
          [stack_permissions] "I" (syscall.Permissions{ .readable = true, .writable = true }),
          [stack_address] "{t1}" (libt.address_space_end),
          [page_size] "{t2}" (mem.page_size),
          [map_id] "I" (@intFromEnum(syscall.Id.map)),
          [main] "{t3}" (&main),
          [exit_id] "I" (@intFromEnum(syscall.Id.exit)),
    );
}

pub fn main() noreturn {
    var gpa = heap.GeneralPurposeAllocator(.{
        .thread_safe = false,
        .safety = false,
    }){};
    var driver_map = DriverMap.init(gpa.allocator());
    populateDriverMap(&driver_map) catch hang();

    if (driver_map.get("ns16550a")) |elf_file|
        _ = loadElf(elf_file) catch hang();

    hang();
}

fn hang() noreturn {
    while (true) {}
}

fn populateDriverMap(driver_map: *DriverMap) !void {
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
        try driver_map.put(file.name, file_data);
    }
}

fn loadElf(elf_bytes: []const u8) !usize {
    var stream = io.fixedBufferStream(elf_bytes);
    const header = try elf.Header.read(&stream);
    if (header.machine != .RISCV)
        return error.InvalidExecutable;
    if (!header.is_64)
        return error.InvalidExecutable;

    var regions = std.BoundedArray(syscall.RegionDescription, 8).init(0) catch unreachable;
    var arguments: [7]usize = undefined;

    var it = header.program_header_iterator(&stream);
    while (try it.next()) |program_header| {
        if (program_header.p_type != elf.PT_LOAD)
            continue;

        const start_address = mem.alignBackward(usize, program_header.p_vaddr, mem.page_size);
        const end_address = mem.alignForward(usize, program_header.p_vaddr + program_header.p_memsz, mem.page_size);
        const pages = (end_address - start_address) / mem.page_size;
        const region = try syscall.allocate(pages, .{ .readable = true, .writable = true, .executable = true }, 0);
        const address = try syscall.map(region, 0);

        var rd: *syscall.RegionDescription = try regions.addOne();
        rd.region_index = @intCast(region);
        rd.start_address = start_address;
        rd.readable = program_header.p_flags & elf.PF_R != 0;
        rd.writable = program_header.p_flags & elf.PF_W != 0;
        rd.executable = program_header.p_flags & elf.PF_X != 0;

        const page_offset = program_header.p_vaddr % mem.page_size;
        const dest: [*]u8 = @ptrFromInt(address + page_offset);
        const source = elf_bytes[program_header.p_offset..][0..program_header.p_filesz];
        @memcpy(dest, source);

        _ = syscall.unmap(address) catch unreachable;
    }

    // Allocate a stack for the process.
    const region = try syscall.allocate(stack_size, .{ .readable = true, .writable = true }, 0);
    var rd: *syscall.RegionDescription = try regions.addOne();
    rd.region_index = @intCast(region);
    rd.start_address = libt.address_space_end - stack_size * mem.page_size;
    rd.readable = true;
    rd.writable = true;
    rd.executable = false;

    // Test sending a message over shared memory region.
    const shared_region = try syscall.allocate(1, .{ .readable = true, .writable = true }, 0);
    rd = try regions.addOne();
    rd.region_index = @intCast(shared_region);
    rd.start_address = 0;
    rd.readable = true;
    rd.writable = false;
    rd.executable = false;

    const addr: [*]u8 = @ptrFromInt(try syscall.map(shared_region, 0));
    @memcpy(addr, "Hello from init!\n");
    arguments[0] = shared_region;

    return syscall.spawn(regions.constSlice(), (&arguments)[0..1], header.entry, libt.address_space_end);
}
