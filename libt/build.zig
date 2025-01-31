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
    executable_options: Build.ExecutableOptions,
    service_options: []const ServiceOptions,
) *Step.Compile {
    const dependency = b.dependency("libt", .{
        .target = executable_options.target,
        .optimize = executable_options.optimize,
        .include_entry_point = true,
    });

    const exe = b.addExecutable(executable_options);
    const module = dependency.module("libt");
    exe.root_module.addImport("libt", module);
    addServices(exe, service_options, module);
    return exe;
}

fn addServices(exe: *Step.Compile, options: []const ServiceOptions, libt_module: *Build.Module) void {
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

fn generateServiceFile(exe: *Step.Compile, options: []const ServiceOptions) Build.LazyPath {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    var buffer = ArrayList(u8).init(arena.allocator());
    defer buffer.deinit();
    var writer = buffer.writer();

    writer.writeAll("const service = @import(\"libt\").service;\n") catch @panic("OOM");
    inline for (options) |option| {
        writer.print(
            \\extern var @"{0s}_start": anyopaque;
            \\pub const @"{0s}": *{1s} = @alignCast(@ptrCast(&@"{0s}_start"));
            \\
        , .{ option.name, @typeName(option.service) }) catch @panic("OOM");
    }

    const b = exe.step.owner;
    const service_file_step = b.addWriteFiles();
    exe.step.dependOn(&service_file_step.step);
    return service_file_step.add("services.zig", buffer.items);
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
            ".{0s} (TYPE = SHT_NOBITS) : ALIGN(0x1000) {{ {0s}_start = .; . += 0x{1x}; }} :{0s}\n",
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
