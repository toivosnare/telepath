const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const mem = std.mem;
const proc = @import("../proc.zig");
const Process = proc.Process;

pub const Result = usize;

pub fn exit(process: *Process) *Process {
    const exit_code = process.context.register_file.a1;
    log.debug("Process with PID {d} is exiting with exit code {d}.", .{ process.id, exit_code });
    process.deinit();

    if (proc.queue_head == null)
        @panic("nothing to run");
    const next_process = proc.queue_head.?;
    proc.dequeue(next_process);
    proc.contextSwitch(next_process);
    return next_process;
}

pub fn identify(process: *Process) Result {
    return process.id;
}

pub fn fork(process: *Process) !Result {
    log.debug("Process with ID {d} is forking.", .{process.id});

    const child_process = try proc.allocate();
    errdefer child_process.deinit();

    try process.children.append(child_process);
    child_process.parent = process;

    @memcpy(
        mem.asBytes(&child_process.context.register_file),
        mem.asBytes(&process.context.register_file),
    );
    child_process.context.register_file.a0 = process.id;
    proc.enqueue(child_process);
    return child_process.id;
}
