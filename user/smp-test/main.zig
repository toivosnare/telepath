const libt = @import("libt");
const syscall = libt.syscall;

comptime {
    _ = libt;
}

pub fn main(args: []usize) !void {
    _ = args;

    const services = @import("services");
    const writer = services.serial.tx.writer();

    try writer.writeAll("Hello from smp-test.\n");

    const pid = libt.syscall.identify() catch unreachable;

    var sector: [512]u8 = undefined;
    if (pid % 2 == 0) {
        services.block.request.write(.{
            .sector = 0,
            .address = @intFromPtr(syscall.translate(&sector) catch unreachable),
            .write = false,
            .token = 22,
        });
        const response = services.block.response.read();
        try writer.print("response: {}\n", .{response});
        try writer.print("sector: {any}\n", .{sector});
    }

    const letter: u8, const delay: usize = if (pid % 2 != 0)
        .{ 'A', 1_000_000 }
    else
        .{ 'B', 2_000_000 };

    libt.sleep(delay / 2) catch unreachable;

    while (true) {
        try writer.writeByte(letter);
        libt.sleep(delay) catch unreachable;
    }
}
