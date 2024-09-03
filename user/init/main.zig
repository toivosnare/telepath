const libt = @import("libt");
const syscall = libt.syscall;

comptime {
    _ = libt;
}

pub fn main() noreturn {
    syscall.exit(2);
}
