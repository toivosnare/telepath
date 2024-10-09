const libt = @import("libt");

comptime {
    _ = libt;
}

pub fn main(args: []usize) noreturn {
    _ = args;

    const stdout = @import("services").stdout;
    stdout.writeSlice("Hello from smp-test.\n");

    const pid = libt.syscall.identify() catch unreachable;
    const letter: u8, const delay: usize = if (pid % 2 != 0)
        .{ 'A', 1_000_000 }
    else
        .{ 'B', 2_000_000 };

    libt.sleep(delay / 2) catch unreachable;

    while (true) {
        stdout.write(letter);
        libt.sleep(delay) catch unreachable;
    }
}
