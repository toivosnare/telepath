const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const heap = std.heap;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Keccak = std.crypto.hash.sha3.Keccak(1600, 32, 0x06, 24);

pub const Test = @import("service/Test.zig");

pub const PF_P: u32 = 1 << 3;

pub fn hash(comptime Service: type) u32 {
    var result: u32 = undefined;
    Keccak.hash(@typeName(Service), @ptrCast(&result), .{});
    result &= ~(@as(u32, 0b1111) << 28);
    result |= @as(u32, 0b0110) << 28;
    return result;
}

pub const Options = struct {
    T: type,
    name: []const u8,
    flags: Flags,

    pub const Flags = packed struct {
        execute: bool = false,
        write: bool = false,
        read: bool = false,
        provide: bool = false,
    };
};

pub fn add(exe: *Step.Compile, options: []const Options, libt_module: *Build.Module) void {
    exe.linker_script = generateLinkerScript(exe, options);
    const b = exe.step.owner;
    const service_module = b.createModule(.{
        .root_source_file = generateServiceFile(exe, options),
        .target = exe.root_module.resolved_target,
        .optimize = exe.root_module.optimize,
    });
    service_module.addImport("libt", libt_module);
    exe.root_module.addImport("services", service_module);
}

fn generateServiceFile(exe: *Step.Compile, options: []const Options) Build.LazyPath {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    var buffer = ArrayList(u8).init(arena.allocator());
    defer buffer.deinit();
    var writer = buffer.writer();

    writer.writeAll("const service = @import(\"libt\").service;\n") catch @panic("OOM");
    inline for (options) |option| {
        writer.print(
            \\extern var @"{s}_start": anyopaque;
            \\pub const @"{s}": *{s} = @alignCast(@ptrCast(&@"{s}_start"));
            \\
        , .{ option.name, option.name, @typeName(option.T), option.name }) catch @panic("OOM");
    }

    const b = exe.step.owner;
    const service_file_step = b.addWriteFiles();
    exe.step.dependOn(&service_file_step.step);
    return service_file_step.add("services.zig", buffer.items);
}

fn generateLinkerScript(exe: *Step.Compile, options: []const Options) Build.LazyPath {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    var buffer = ArrayList(u8).init(arena.allocator());
    defer buffer.deinit();
    var writer = buffer.writer();

    writer.writeAll(
        \\PHDRS {
        \\rodata PT_LOAD FLAGS(0x4);
        \\text   PT_LOAD FLAGS(0x5);
        \\data   PT_LOAD FLAGS(0x6);
        \\
    ) catch @panic("OOM");
    inline for (options) |option| {
        writer.print("{s} 0x{x} FLAGS(0x{x});\n", .{ option.name, hash(option.T), @as(u4, @bitCast(option.flags)) }) catch @panic("OOM");
    }
    writer.writeAll("}\n\n") catch @panic("OOM");

    writer.writeAll(
        \\SECTIONS {
        \\. = 0x1000;
        \\.rodata : ALIGN(0x1000) { *(.rodata .rodata.*)             } :rodata
        \\.text   : ALIGN(0x1000) { *(.text .text.*)                 } :text
        \\.data   : ALIGN(0x1000) { *(.data .data.* .sdata .sdata.*) } :data
        \\.bss    : ALIGN(0x1000) { *(.bss .bss.*)                   } :data
        \\
    ) catch @panic("OOM");
    inline for (options) |option| {
        const page_size = 4096;
        const service_size = mem.alignForward(usize, @sizeOf(option.T), page_size);
        writer.print(
            ".{s} (TYPE = SHT_NOBITS) : ALIGN(0x1000) {{ {s}_start = .; . += 0x{x}; }} :{s}\n",
            .{ option.name, option.name, service_size, option.name },
        ) catch @panic("OOM");
    }
    writer.writeAll("}\n") catch @panic("OOM");

    const b = exe.step.owner;
    const linker_script_step = b.addWriteFiles();
    exe.step.dependOn(&linker_script_step.step);
    const linker_script_name = b.fmt("{s}.ld", .{exe.name});
    return linker_script_step.add(linker_script_name, buffer.items);
}
