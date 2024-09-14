const std = @import("std");
const Keccak = std.crypto.hash.sha3.Keccak(1600, 32, 0x06, 24);
const libt = @import("libt.zig");
const Mutex = libt.sync.Mutex;
const Condvar = libt.sync.Condvar;

pub const byte_stream = @import("service/byte_stream.zig");

pub fn hash(comptime Service: type) u32 {
    var result: u32 = undefined;
    Keccak.hash(@typeName(Service), @ptrCast(&result), .{});
    result &= ~(@as(u32, 0b1111) << 28);
    result |= @as(u32, 0b0110) << 28;
    return result;
}

pub const Flags = packed struct(u4) {
    executable: bool,
    writable: bool,
    readable: bool,
    provide: bool,

    pub const mask_p = 1 << @bitOffsetOf(Flags, "provide");
    pub const mask_r = 1 << @bitOffsetOf(Flags, "redable");
    pub const mask_w = 1 << @bitOffsetOf(Flags, "writable");
    pub const mask_x = 1 << @bitOffsetOf(Flags, "executable");
};

pub fn Channel(comptime T: type, comptime c: usize, comptime direction: enum { receive, transmit, bidirectional }) type {
    return extern struct {
        buffer: [capacity]T,
        length: usize,
        read_index: usize,
        write_index: usize,
        mutex: Mutex,
        empty: Condvar,
        full: Condvar,

        pub const capacity: usize = c;
        const Self = @This();

        pub fn init(self: *Self) void {
            self.* = .{
                .mutex = .{},
                .empty = .{},
                .full = .{},
                .length = 0,
                .read_index = 0,
                .write_index = 0,
                .buffer = undefined,
            };
        }

        pub fn read(self: *Self) T {
            if (direction == .transmit)
                @compileError("Cannot read from transmit channel.");

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.length == 0)
                self.empty.wait(&self.mutex);

            const result = self.buffer[self.read_index];
            self.read_index = (self.read_index + 1) % capacity;
            self.length -= 1;

            self.full.notify(.one);
            return result;
        }

        pub fn write(self: *Self, item: T) void {
            if (direction == .receive)
                @compileError("Cannot write to receive channel.");

            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.length == capacity)
                self.full.wait(&self.mutex);

            self.buffer[self.write_index] = item;
            self.write_index = (self.write_index + 1) % capacity;
            self.length += 1;

            self.empty.notify(.one);
        }
    };
}
