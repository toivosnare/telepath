const std = @import("std");
const log = std.log.scoped(.trap);
const meta = std.meta;
const libt = @import("libt");
const riscv = @import("riscv.zig");
const mm = @import("mm.zig");
const proc = @import("proc.zig");
const Thread = proc.Thread;
const Hart = proc.Hart;

pub const syscall = @import("trap/syscall.zig");

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
        .ssie = true,
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

export fn handleTrap2(context: ?*Thread.Context, hart_index: proc.Hart.Index) noreturn {
    const current_thread = if (context) |c| c.thread() else null;
    const scause = riscv.scause.read();

    // TODO: check thread ref_count/exit status in all trap code paths?
    if (scause.interrupt) {
        handleInterrupt(scause.code.interrupt, current_thread, hart_index);
    } else {
        handleException(scause.code.exception, current_thread);
    }
}

fn handleInterrupt(code: riscv.scause.InterruptCode, current_thread: ?*Thread, hart_index: proc.Hart.Index) noreturn {
    log.debug("Interrupt code={s} on hart index={d}", .{ @tagName(code), hart_index });
    switch (code) {
        .supervisor_software_interrupt => proc.scheduler.scheduleNext(current_thread, hart_index),
        .supervisor_timer_interrupt => handleTimerInterrupt(current_thread, hart_index),
        .supervisor_external_interrupt => proc.interrupt.check(current_thread, hart_index),
        else => @panic("unhandled interrupt"),
    }
}

fn handleTimerInterrupt(current_thread: ?*Thread, hart_index: proc.Hart.Index) noreturn {
    proc.timeout.check(riscv.time.read());
    proc.scheduler.scheduleNext(current_thread, hart_index);
}

fn handleException(code: riscv.scause.ExceptionCode, current_thread: ?*Thread) noreturn {
    if (current_thread == null)
        @panic("exception from idle");
    const thread = current_thread.?;

    const stval = riscv.stval.read();
    log.debug("Exception code={s} stval={x} on hart index={d}", .{ @tagName(code), stval, thread.context.hart_index });

    thread.lock.lock();
    if (thread.ref_count == 0) {
        const hart_index = thread.context.hart_index;
        proc.freeThread(thread);
        proc.scheduler.scheduleNext(null, hart_index);
    }
    if (thread.state == .exited) {
        thread.lock.unlock();
        proc.scheduler.scheduleNext(null, thread.context.hart_index);
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
            log.warn("Thread id={d} crashed ({s})", .{ thread.id, @tagName(code) });
            thread.exit(libt.syscall.packResult(error.Crashed));
            thread.lock.unlock();
            proc.scheduler.scheduleNext(null, thread.context.hart_index);
        },
        .environment_call_from_u_mode => handleSyscall(thread),
        .instruction_page_fault => thread.handlePageFault(stval, .execute),
        .load_page_fault => thread.handlePageFault(stval, .load),
        .store_amo_page_fault => thread.handlePageFault(stval, .store),
        else => @panic("unhandled exception"),
    }
}

fn handleSyscall(current_thread: *Thread) noreturn {
    current_thread.context.pc += 4;
    const syscall_id_int = current_thread.context.a0;
    const syscall_id = meta.intToEnum(libt.syscall.Id, syscall_id_int) catch {
        log.warn("Invalid syscall ID {d}", .{syscall_id_int});
        current_thread.context.a0 = libt.syscall.packResult(error.InvalidParameter);
        proc.scheduler.scheduleCurrent(current_thread);
    };
    const result = switch (syscall_id) {
        .process_allocate => syscall.processAllocate(current_thread),
        .process_free => syscall.processFree(current_thread),
        .process_share => syscall.processShare(current_thread),
        .process_translate => syscall.processTranslate(current_thread),
        .region_allocate => syscall.regionAllocate(current_thread),
        .region_free => syscall.regionFree(current_thread),
        .region_share => syscall.regionShare(current_thread),
        .region_map => syscall.regionMap(current_thread),
        .region_unmap => syscall.regionUnmap(current_thread),
        .region_read => syscall.regionRead(current_thread),
        .region_write => syscall.regionWrite(current_thread),
        .region_ref_count => syscall.regionRefCount(current_thread),
        .region_size => syscall.regionSize(current_thread),
        .thread_allocate => syscall.threadAllocate(current_thread),
        .thread_free => syscall.threadFree(current_thread),
        .thread_share => syscall.threadShare(current_thread),
        .thread_kill => syscall.threadKill(current_thread),
        .exit => syscall.exit(current_thread),
        .synchronize => syscall.synchronize(current_thread),
        .ack => syscall.ack(current_thread),
    };
    current_thread.context.a0 = libt.syscall.packResult(result);
    proc.scheduler.scheduleCurrent(current_thread);
}
