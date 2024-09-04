const std = @import("std");
const libt = @import("libt");
const elf = std.elf;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const process = std.process;
const assert = std.debug.assert;
const tix = libt.tix;

pub fn main() !void {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout_file = std.io.getStdOut();
    const stdout = stdout_file.writer();

    const argv = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, argv);

    const input_file = if (argv.len > 1)
        try fs.cwd().openFile(argv[1], .{ .mode = .read_only })
    else
        io.getStdIn();
    defer input_file.close();

    // TIX header.
    const elf_header = try elf.Header.read(input_file);
    var it = elf_header.program_header_iterator(input_file);
    var region_amount: u8 = 0;
    while (try it.next()) |program_header| {
        if (program_header.p_type == elf.PT_LOAD)
            region_amount += 1;
    }
    const tix_header = tix.Header{
        .region_amount = region_amount,
        .entry_point = elf_header.entry,
    };
    try stdout.writeStruct(tix_header);

    // Region headers.
    var offset: u64 = @sizeOf(tix.Header) + region_amount * @sizeOf(tix.RegionHeader);
    it.index = 0;
    while (try it.next()) |program_header| {
        if (program_header.p_type != elf.PT_LOAD)
            continue;
        const region_header = tix.RegionHeader{
            .offset = offset,
            .load_address = program_header.p_vaddr,
            .file_size = program_header.p_filesz,
            .memory_size = program_header.p_memsz,
            .readable = program_header.p_flags & elf.PF_R != 0,
            .writable = program_header.p_flags & elf.PF_W != 0,
            .executable = program_header.p_flags & elf.PF_X != 0,
        };
        try stdout.writeStruct(region_header);
        offset += program_header.p_filesz;
    }

    // Data.
    it.index = 0;
    while (try it.next()) |program_header| {
        if (program_header.p_type != elf.PT_LOAD)
            continue;
        const buffer = try allocator.alloc(u8, program_header.p_filesz);
        const bytes_read = try input_file.pread(buffer, program_header.p_offset);
        assert(bytes_read == program_header.p_filesz);
        try stdout.writeAll(buffer);
    }
}
