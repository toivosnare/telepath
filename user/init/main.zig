const std = @import("std");
const elf = std.elf;
const tar = std.tar;
const io = std.io;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const syscall = libt.syscall;
const service = libt.service;

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
    syscall.wait(null, 0, math.maxInt(usize)) catch unreachable;
    unreachable;
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

const Regions = std.BoundedArray(syscall.RegionDescription, 8);
const Arguments = std.BoundedArray(usize, 7);

fn loadElf(elf_bytes: []const u8) !usize {
    var stream = io.fixedBufferStream(elf_bytes);
    const header = try elf.Header.read(&stream);
    if (header.machine != .RISCV)
        return error.InvalidExecutable;
    if (!header.is_64)
        return error.InvalidExecutable;

    var regions = Regions.init(0) catch unreachable;
    var arguments = Arguments.init(0) catch unreachable;

    var it = header.program_header_iterator(&stream);
    while (try it.next()) |program_header| {
        if (program_header.p_type == elf.PT_LOAD) {
            try handleLoadSegment(program_header, &regions, elf_bytes);
        } else if (program_header.p_type >= elf.PT_LOOS and program_header.p_type <= elf.PT_HIOS) {
            try handleServiceSegment(program_header, &regions, &arguments);
        }
    }

    // Allocate a stack for the process.
    const region = try syscall.allocate(stack_size, .{ .readable = true, .writable = true }, null);
    var rd: *syscall.RegionDescription = try regions.addOne();
    rd.region = region;
    rd.start_address = @ptrFromInt(libt.address_space_end - stack_size * mem.page_size);
    rd.readable = true;
    rd.writable = true;
    rd.executable = false;

    return syscall.spawn(regions.constSlice(), arguments.constSlice(), @ptrFromInt(header.entry), @ptrFromInt(libt.address_space_end));
}

fn handleLoadSegment(header: elf.Elf64_Phdr, regions: *Regions, elf_bytes: []const u8) !void {
    const start_address = mem.alignBackward(usize, header.p_vaddr, mem.page_size);
    const end_address = mem.alignForward(usize, header.p_vaddr + header.p_memsz, mem.page_size);
    const size = (end_address - start_address) / mem.page_size;
    const region = try syscall.allocate(size, .{ .readable = true, .writable = true, .executable = true }, null);
    const address = try syscall.map(region, null);

    var rd: *syscall.RegionDescription = try regions.addOne();
    rd.region = region;
    rd.start_address = @ptrFromInt(start_address);
    rd.readable = header.p_flags & elf.PF_R != 0;
    rd.writable = header.p_flags & elf.PF_W != 0;
    rd.executable = header.p_flags & elf.PF_X != 0;

    const page_offset = header.p_vaddr % mem.page_size;
    const dest: [*]u8 = @as([*]u8, @ptrCast(address)) + page_offset;
    const source = elf_bytes[header.p_offset..][0..header.p_filesz];
    @memcpy(dest, source);

    _ = syscall.unmap(address) catch unreachable;
}

fn handleServiceSegment(header: elf.Elf64_Phdr, regions: *Regions, arguments: *Arguments) !void {
    const start_address = mem.alignBackward(usize, header.p_vaddr, mem.page_size);
    const end_address = mem.alignForward(usize, header.p_vaddr + header.p_memsz, mem.page_size);
    const size = (end_address - start_address) / mem.page_size;

    const region = try if (header.p_flags & service.Flags.mask_p != 0)
        handleProvidedServiceSegment(size, header.p_type)
    else
        handleConsumedServiceSegment();

    var rd: *syscall.RegionDescription = try regions.addOne();
    rd.region = region;
    rd.start_address = @ptrFromInt(start_address);
    rd.readable = header.p_flags & elf.PF_R != 0;
    rd.writable = header.p_flags & elf.PF_W != 0;
    rd.executable = header.p_flags & elf.PF_X != 0;
    try arguments.append(region);
}

fn handleProvidedServiceSegment(size: usize, id: usize) !usize {
    const region = try syscall.allocate(size, .{ .readable = true, .writable = true, .executable = true }, null);

    if (id == service.hash(service.byte_stream)) {
        const byte_stream: *align(mem.page_size) service.byte_stream.consume.Type = @ptrCast(try syscall.map(region, null));
        byte_stream.writeSlice("Hello from init!\n");
        _ = try syscall.unmap(@ptrCast(byte_stream));
    }

    return region;
}

fn handleConsumedServiceSegment() !usize {
    return error.NotImplemented;
}
