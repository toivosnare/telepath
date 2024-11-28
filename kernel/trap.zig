const std = @import("std");
const log = std.log.scoped(.trap);
const meta = std.meta;
const math = std.math;
const assert = std.debug.assert;
const mm = @import("mm.zig");
const riscv = @import("riscv.zig");
const proc = @import("proc.zig");
const libt = @import("libt");
const syscall = @import("trap/syscall.zig");
const Process = proc.Process;
const Hart = proc.Hart;

pub const Plic = @import("trap/plic.zig").Plic;
pub var plic: Plic align(@sizeOf(mm.Page)) linksection(".plic") = undefined;

pub fn init() void {
    riscv.stvec.write(.{
        .mode = .direct,
        .base = @intCast(@intFromPtr(&handleTrap) >> 2),
    });
    enableInterrupts();

    // Some syscalls need to access user space memory.
    riscv.sstatus.set(.sum);
}

pub inline fn enableInterrupts() void {
    log.debug("Enabling interrupts", .{});
    riscv.sie.write(.{
        .ssie = false,
        .stie = true,
        .seie = true,
        .lcofie = false,
    });
}

pub inline fn disableInterrupts() void {
    log.debug("Disabling interrupts", .{});
    riscv.sie.write(.{
        .ssie = false,
        .stie = false,
        .seie = false,
        .lcofie = false,
    });
}

pub fn onAddressTranslationEnabled(hart_index: Hart.Index) void {
    riscv.stvec.write(.{
        .mode = .direct,
        .base = @intCast((@intFromPtr(&handleTrap) + mm.kernel_offset) >> 2),
    });

    const hart_id = proc.harts[hart_index].id;
    plic.setTreshold(hart_id, 0);
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
    log.debug("Interrupt code={s} on hart index={d}", .{ @tagName(code), hart_index });
    switch (code) {
        .supervisor_timer_interrupt => handleTimerInterrupt(current_process, hart_index),
        .supervisor_external_interrupt => proc.interrupt.check(current_process, hart_index),
        else => @panic("unhandled interrupt"),
    }
}

fn handleTimerInterrupt(current_process: ?*Process, hart_index: proc.Hart.Index) noreturn {
    proc.timeout.check(riscv.time.read());
    const c = if (current_process) |current| blk: {
        current.lock.lock();
        defer current.lock.unlock();

        if (current.killed) {
            log.debug("Freeing killed process id={d}", .{current.id});
            proc.free(current);
            break :blk null;
        } else {
            break :blk current;
        }
    } else null;
    proc.scheduler.scheduleNext(c, hart_index);
}

fn handleException(code: riscv.scause.ExceptionCode, current_process: ?*Process) noreturn {
    if (current_process == null)
        @panic("exception from idle");
    const process = current_process.?;

    const stval = riscv.stval.read();
    log.debug("Exception code={s} stval={x} on hart index={d}", .{ @tagName(code), stval, process.context.hart_index });

    process.lock.lock();
    if (process.killed) {
        log.debug("Freeing killed process id={d}", .{process.id});
        proc.free(process);
        process.lock.unlock();
        proc.scheduler.scheduleNext(null, process.context.hart_index);
    }
    switch (code) {
        .instruction_address_misaligned,
        .instruction_access_fault,
        .illegal_instruction,
        .breakpoint,
        .load_address_misaligned,
        .load_access_fault,
        .store_amo_address_misaligned,
        .store_amo_access_fault,
        => {
            log.warn("Process id={d} crashed ({s})", .{ process.id, @tagName(code) });
            process.exit(libt.syscall.packResult(error.Crashed));
            proc.scheduler.scheduleNext(null, process.context.hart_index);
        },
        .environment_call_from_u_mode => handleSyscall(process),
        .instruction_page_fault => process.handlePageFault(stval, .execute),
        .load_page_fault => process.handlePageFault(stval, .load),
        .store_amo_page_fault => process.handlePageFault(stval, .store),
        else => @panic("unhandled exception"),
    }
}

fn handleSyscall(current_process: *Process) noreturn {
    current_process.context.pc += 4;
    const syscall_id_int = current_process.context.a0;
    const syscall_id = meta.intToEnum(libt.syscall.Id, syscall_id_int) catch {
        log.warn("Invalid syscall ID {d}", .{syscall_id_int});
        current_process.context.a0 = libt.syscall.packResult(error.InvalidParameter);
        proc.scheduler.scheduleCurrent(current_process);
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
        .wait => syscall.wait(current_process),
        .wake => syscall.wake(current_process),
        .translate => syscall.translate(current_process),
        .acknowledge => syscall.acknowledge(current_process),
    };
    current_process.context.a0 = libt.syscall.packResult(result);
    proc.scheduler.scheduleCurrent(current_process);
}
