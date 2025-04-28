const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const heap = std.heap;
const mem = std.mem;
const ArrayList = std.ArrayList;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_entry_point = b.option(bool, "include_entry_point", "") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "include_entry_point", include_entry_point);

    const module = b.addModule("libt", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("root.zig"),
    });
    module.addOptions("options", options);
}

pub const service = @import("service.zig");

pub const ServiceOptions = struct {
    name: []const u8,
    service: type,
    mode: enum { provide, consume } = .consume,
};
pub fn addTelepathExecutable(
    b: *Build,
    name: []const u8,
    root_source_file: Build.LazyPath,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    service_options: []const ServiceOptions,
) *Step.Compile {
    const libt = b.dependency("libt", .{
        .target = target,
        .optimize = optimize,
        .include_entry_point = true,
    });
    const libt_module = libt.module("libt");

    const root_module = b.createModule(.{
        .root_source_file = root_source_file,
        .imports = &[_]Build.Module.Import{.{
            .name = "libt",
            .module = libt_module,
        }},
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    exe.linker_script = generateLinkerScript(exe, service_options);
    return exe;
}

fn generateLinkerScript(exe: *Step.Compile, options: []const ServiceOptions) Build.LazyPath {
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
        const flags: service.Flags = .{
            .provide = option.mode == .provide,
            .readable = true,
            .writable = true, // TODO: add read-only mode?
            .executable = false,
        };
        writer.print("{s} 0x{x} FLAGS(0x{x});\n", .{ option.name, service.hash(option.service), @as(u4, @bitCast(flags)) }) catch @panic("OOM");
    }
    writer.writeAll("}\n\n") catch @panic("OOM");

    writer.writeAll(
        \\SECTIONS {
        \\. = 0x1000;
        \\.rodata : ALIGN(0x1000) { *(.rodata .rodata.*)             } :rodata
        \\.text   : ALIGN(0x1000) { *(.text .text.*)                 } :text
        \\.data   : ALIGN(0x1000) { *(.data .data.* .sdata .sdata.*) } :data
        \\.bss    : ALIGN(0x1000) { *(.bss .bss.* .sbss .sbss.*)     } :data
        \\
    ) catch @panic("OOM");
    inline for (options) |option| {
        const page_size = 4096;
        const service_size = mem.alignForward(usize, @sizeOf(option.service), page_size);
        writer.print(
            ".{0s} (TYPE = SHT_NOBITS) : ALIGN(0x1000) {{ {0s} = .; . += 0x{1x}; }} :{0s}\n",
            .{ option.name, service_size },
        ) catch @panic("OOM");
    }
    writer.writeAll("}\n") catch @panic("OOM");

    const b = exe.step.owner;
    const linker_script_step = b.addWriteFiles();
    exe.step.dependOn(&linker_script_step.step);
    const linker_script_name = b.fmt("{s}.ld", .{exe.name});
    return linker_script_step.add(linker_script_name, buffer.items);
}
