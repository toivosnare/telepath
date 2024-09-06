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

comptime {
    _ = libt;
}

const DriverMap = std.StringHashMap([]const u8);

pub fn main(args: []usize) !usize {
    _ = args;

    var gpa = heap.GeneralPurposeAllocator(.{
        .thread_safe = false,
        .safety = false,
    }){};
    var driver_map = DriverMap.init(gpa.allocator());
    try populateDriverMap(&driver_map);

    if (driver_map.get("ns16550a")) |elf_file|
        _ = try loadElf(elf_file);

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

    return syscall.spawn(regions.constSlice(), &arguments, header.entry);
}
