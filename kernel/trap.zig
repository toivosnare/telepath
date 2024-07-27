const std = @import("std");
const log = std.log;
const meta = std.meta;
const mm = @import("mm.zig");
const csr = @import("csr.zig");
const proc = @import("proc.zig");
const libt = @import("libt");
const Process = proc.Process;

pub fn init() void {
    csr.stvec.write(.{
        .mode = .direct,
        .base = @intCast(@intFromPtr(&handleTrap) >> 2),
    });
    csr.sie.write(.{
        .ssie = true,
        .stie = true,
        .seie = true,
        .lcofie = true,
    });
    csr.sstatus.set(.sie);
}

pub fn onAddressTranslationEnabled() void {
    csr.stvec.write(.{
        .mode = .direct,
        .base = @intCast((@intFromPtr(&handleTrap) + mm.kernel_offset) >> 2),
    });
}

extern fn handleTrap() align(4) callconv(.Naked) noreturn;

export fn handleTrap2(context: *Process.Context) noreturn {
    const process = context.process();
    const scause = csr.scause.read();
    if (scause.interrupt) {
        handleInterrupt(scause.code.interrupt, process);
    } else {
        handleException(scause.code.exception, process);
    }
    @panic("trap");
}

fn handleInterrupt(code: csr.scause.InterruptCode, process: *Process) void {
    _ = process;
    log.debug("Interrupt: code={s}", .{@tagName(code)});
}

fn handleException(code: csr.scause.ExceptionCode, process: *Process) void {
    const stval = csr.stval.read();
    log.debug("Exception: code={s}, stval={x}", .{ @tagName(code), stval });
    switch (code) {
        .environment_call_from_u_mode => handleSyscall(process),
        else => @panic("unhandled exception"),
    }
}

fn handleSyscall(process: *Process) void {
    const syscall_id_int = process.context.register_file.a0;
    const syscall_id = meta.intToEnum(libt.SyscallId, syscall_id_int) catch {
        log.warn("Invalid syscall ID {d}", .{syscall_id_int});
        return;
    };
    switch (syscall_id) {
        .exit => log.debug("Process should exit", .{}),
        else => @panic("unhandled syscall"),
    }
}
