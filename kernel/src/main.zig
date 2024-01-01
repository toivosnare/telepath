const std = @import("std");
const log = std.log;
const mem = std.mem;
const dtb = @import("dtb");

pub const std_options = struct {
    pub const logFn = myLogFn;
};

fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ if (scope == std.log.default_log_scope) "" else "(" ++ @tagName(scope) ++ ") ";
    writer.print(prefix ++ format ++ "\n", args) catch return;
}

const writer: std.io.Writer(void, error{}, writeFn) = .{ .context = {} };

fn writeFn(_: void, bytes: []const u8) error{}!usize {
    sbi_ecall(0x4442434E, 0x0, bytes.len, @intFromPtr(bytes.ptr), 0, 0, 0, 0);
    return bytes.len;
}

fn sbi_ecall(ext: usize, fid: usize, arg0: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) void {
    asm volatile (
        \\ecall
        :
        : [a0] "{a0}" (arg0),
          [a1] "{a1}" (arg1),
          [a2] "{a2}" (arg2),
          [a3] "{a3}" (arg3),
          [a4] "{a4}" (arg4),
          [a5] "{a5}" (arg5),
          [a6] "{a6}" (fid),
          [a7] "{a7}" (ext),
        : "memory"
    );
}

extern const fdt_address: [*]const u8;

export fn main() noreturn {
    log.info("Kernel booting...", .{});
    log.debug("FDT address: {*}", .{fdt_address});

    var traverser: dtb.Traverser = undefined;
    traverser.init(fdt_address) catch @panic("Invalid device tree");

    const State = enum {
        start,
        chosen,
        memory,
        plic,
        clint,
    };
    var state: State = .start;

    var initrd_start: ?u32 = null;
    var initrd_end: ?u32 = null;
    var memory_start: ?u32 = null;
    var memory_size: ?u32 = null;
    var plic_start: ?u32 = null;
    var plic_size: ?u32 = null;
    var clint_start: ?u32 = null;
    var clint_size: ?u32 = null;

    while (true) {
        const event = traverser.event() catch break;
        switch (event) {
            .BeginNode => |b| {
                if (mem.eql(u8, b, "chosen")) {
                    state = .chosen;
                } else if (mem.startsWith(u8, b, "memory")) {
                    state = .memory;
                } else if (mem.startsWith(u8, b, "plic")) {
                    state = .plic;
                } else if (mem.startsWith(u8, b, "clint")) {
                    state = .clint;
                }
            },
            .Prop => |p| {
                switch (state) {
                    .chosen => {
                        if (mem.eql(u8, p.name, "linux,initrd-start")) {
                            initrd_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                        } else if (mem.eql(u8, p.name, "linux,initrd-end")) {
                            initrd_end = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value))).*);
                        }
                    },
                    .memory => {
                        if (mem.eql(u8, p.name, "reg")) {
                            memory_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            memory_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .plic => {
                        if (mem.eql(u8, p.name, "reg")) {
                            plic_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            plic_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    .clint => {
                        if (mem.eql(u8, p.name, "reg")) {
                            clint_start = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[4..8]))).*);
                            clint_size = mem.bigToNative(u32, @as(*const u32, @ptrCast(@alignCast(p.value[12..16]))).*);
                        }
                    },
                    else => continue,
                }
            },
            .EndNode => {
                state = .start;
            },
            .End => break,
        }
    }
    log.debug("initrd_start: {?x}, initrd_end: {?x}", .{ initrd_start, initrd_end });
    log.debug("memory_start: {?x}, memory_size: {?x}", .{ memory_start, memory_size });
    log.debug("plic_start: {?x}, plic_size: {?x}", .{ plic_start, plic_size });
    log.debug("clint_start: {?x}, clint_size: {?x}", .{ clint_start, clint_size });
    while (true) {}
}
