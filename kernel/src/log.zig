const std = @import("std");

pub fn logFn(
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
    sbi_ecall(0x4442434E, 0x0, bytes.len, bytes, 0, 0, 0, 0);
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
