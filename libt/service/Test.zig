write_ptr: usize,
buffer: [100]u8,

const Test = @This();

pub fn putc(self: *Test, c: u8) void {
    self.buffer[self.write_ptr] = c;
    self.write_ptr += 1;
}

pub fn puts(self: *Test, s: []const u8) void {
    for (s) |c|
        self.putc(c);
}
