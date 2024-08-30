const std = @import("std");
const log = std.log;
const meta = std.meta;
const math = std.math;
const mm = @import("mm.zig");
const csr = @import("csr.zig");
const proc = @import("proc.zig");
const libt = @import("libt");
const sbi = @import("sbi");
const syscall = @import("trap/syscall.zig");
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

export fn handleTrap2(context: *Process.Context) *Process.Context {
    const current_process = context.process();
    const scause = csr.scause.read();
    const next_process = if (scause.interrupt)
        handleInterrupt(scause.code.interrupt, current_process)
    else
        handleException(scause.code.exception, current_process);
    return &next_process.context;
}

fn handleInterrupt(code: csr.scause.InterruptCode, current_process: *Process) *Process {
    log.debug("Interrupt: code={s}", .{@tagName(code)});
    return switch (code) {
        .supervisor_timer_interrupt => handleTimerInterrupt(current_process),
        else => @panic("unhandled interrupt"),
    };
}

fn handleTimerInterrupt(current_process: *Process) *Process {
    if (proc.queue_head) |next_process| {
        proc.enqueue(current_process);
        proc.dequeue(next_process);
        proc.contextSwitch(next_process);
        sbi.time.setTimer(csr.time.read() + 10 * proc.quantum_ns);
        return next_process;
    } else {
        sbi.time.setTimer(csr.time.read() + 10 * proc.quantum_ns);
        return current_process;
    }
}

fn handleException(code: csr.scause.ExceptionCode, current_process: *Process) *Process {
    const stval = csr.stval.read();
    log.debug("Exception: code={s}, stval={x}", .{ @tagName(code), stval });
    return switch (code) {
        .environment_call_from_u_mode => handleSyscall(current_process),
        else => @panic("unhandled exception"),
    };
}

fn handleSyscall(current_process: *Process) *Process {
    current_process.context.register_file.pc += 4;
    const syscall_id_int = current_process.context.register_file.a0;
    const syscall_id = meta.intToEnum(libt.SyscallId, syscall_id_int) catch {
        log.warn("Invalid syscall ID {d}", .{syscall_id_int});
        current_process.context.register_file.a0 = math.maxInt(usize);
        return current_process;
    };
    if (syscall_id == .exit) {
        return syscall.exit(current_process);
    }
    const result: usize = switch (syscall_id) {
        .exit => unreachable,
        .identify => syscall.identify(current_process),
        .fork => syscall.fork(current_process),
        else => @panic("unhandled syscall"),
    } catch |e| switch (e) {
        else => math.maxInt(usize),
    };
    current_process.context.register_file.a0 = result;
    return current_process;
}
