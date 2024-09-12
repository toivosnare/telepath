const std = @import("std");
const log = std.log;
const meta = std.meta;
const math = std.math;
const assert = std.debug.assert;
const mm = @import("mm.zig");
const riscv = @import("riscv.zig");
const proc = @import("proc.zig");
const libt = @import("libt");
const syscall = @import("trap/syscall.zig");
const Process = proc.Process;

pub fn init() void {
    riscv.stvec.write(.{
        .mode = .direct,
        .base = @intCast(@intFromPtr(&handleTrap) >> 2),
    });
    riscv.sie.write(.{
        .ssie = true,
        .stie = true,
        .seie = true,
        .lcofie = true,
    });
    riscv.sstatus.set(.sie);

    // Some syscall need to access user space memory.
    riscv.sstatus.set(.sum);
}

pub fn onAddressTranslationEnabled() void {
    riscv.stvec.write(.{
        .mode = .direct,
        .base = @intCast((@intFromPtr(&handleTrap) + mm.kernel_offset) >> 2),
    });
}

extern fn handleTrap() align(4) callconv(.Naked) noreturn;

export fn handleTrap2(context: ?*Process.Context, hart_index: proc.Hart.Index) noreturn {
    const current_process = if (context) |c| c.process() else null;
    const scause = riscv.scause.read();

    if (scause.interrupt) {
        handleInterrupt(scause.code.interrupt, current_process, hart_index);
    } else {
        handleException(scause.code.exception, current_process);
    }
}

fn handleInterrupt(code: riscv.scause.InterruptCode, current_process: ?*Process, hart_index: proc.Hart.Index) noreturn {
    log.debug("Interrupt: code={s}", .{@tagName(code)});
    switch (code) {
        .supervisor_timer_interrupt => proc.scheduleNext(current_process, hart_index),
        else => @panic("unhandled interrupt"),
    }
}

fn handleException(code: riscv.scause.ExceptionCode, current_process: ?*Process) noreturn {
    if (current_process == null)
        @panic("exception from idle");

    const stval = riscv.stval.read();
    log.debug("Exception: code={s}, stval={x}", .{ @tagName(code), stval });

    switch (code) {
        .environment_call_from_u_mode => handleSyscall(current_process.?),
        .instruction_page_fault,
        .load_page_fault,
        .store_amo_page_fault,
        => current_process.?.handlePageFault(stval),
        else => @panic("unhandled exception"),
    }
}

fn handleSyscall(current_process: *Process) noreturn {
    current_process.context.pc += 4;
    const syscall_id_int = current_process.context.a0;
    const syscall_id = meta.intToEnum(libt.syscall.Id, syscall_id_int) catch {
        log.warn("Invalid syscall ID {d}", .{syscall_id_int});
        current_process.context.a0 = libt.syscall.packResult(error.InvalidParameter);
        proc.scheduleCurrent(current_process);
    };
    const result = switch (syscall_id) {
        .exit => syscall.exit(current_process),
        .identify => syscall.identify(current_process),
        .fork => syscall.fork(current_process),
        .spawn => syscall.spawn(current_process),
        .kill => syscall.kill(current_process),
        .allocate => syscall.allocate(current_process),
        .map => syscall.map(current_process),
        .share => syscall.share(current_process),
        .refcount => syscall.refcount(current_process),
        .unmap => syscall.unmap(current_process),
        .free => syscall.free(current_process),
        else => @panic("unhandled syscall"),
    };
    current_process.context.a0 = libt.syscall.packResult(result);
    proc.scheduleCurrent(current_process);
}
