const std = @import("std");
const assert = std.debug.assert;
const io = std.io;
const AnyWriter = io.AnyWriter;
const AnyReader = io.AnyReader;
const Keccak = std.crypto.hash.sha3.Keccak(1600, 32, 0x06, 24);
const libt = @import("libt.zig");
const Mutex = libt.sync.Mutex;
const Condvar = libt.sync.Condvar;

pub const serial_driver = @import("service/serial_driver.zig");
pub const block_driver = @import("service/block_driver.zig");
pub const file_system = @import("service/file_system.zig");

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
    pub const mask_r = 1 << @bitOffsetOf(Flags, "readable");
    pub const mask_w = 1 << @bitOffsetOf(Flags, "writable");
    pub const mask_x = 1 << @bitOffsetOf(Flags, "executable");
};

pub fn Channel(comptime T: type, comptime c: usize, comptime direction: enum { receive, transmit, bidirectional }) type {
    return extern struct {
        buffer: [capacity]T = undefined,
        length: usize = 0,
        read_index: usize = 0,
        write_index: usize = 0,
        mutex: Mutex = .{},
        empty: Condvar = .{},
        full: Condvar = .{},

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

        pub fn isEmpty(self: Self) bool {
            return self.length == 0;
        }

        pub fn isFull(self: Self) bool {
            return self.length == capacity;
        }

        pub fn freeLength(self: Self) usize {
            return capacity - self.length;
        }

        pub fn read(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.isEmpty())
                self.empty.wait(&self.mutex);

            const result = self.readLockedAssumeCapacity();

            self.full.notify(.one);
            return result;
        }

        pub fn readLockedAssumeCapacity(self: *Self) T {
            if (direction == .transmit)
                @compileError("Cannot read from transmit channel.");

            assert(!self.isEmpty());
            const result = self.buffer[self.read_index];
            self.read_index = (self.read_index + 1) % capacity;
            self.length -= 1;
            return result;
        }

        pub fn readSlice(self: *Self, result: []T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var bytes_read: usize = 0;
            while (bytes_read < result.len) {
                while (self.isEmpty())
                    self.empty.wait(&self.mutex);

                const bytes_to_read = result.len - bytes_read;
                const n = @min(self.length, bytes_to_read);
                self.readSliceLockedAssumeCapacity(result[bytes_read..][0..n]);
                bytes_read += n;

                self.full.notify(.one);
            }
        }

        pub fn readSliceLockedAssumeCapacity(self: *Self, result: []T) void {
            if (direction == .transmit)
                @compileError("Cannot read from transmit channel.");

            assert(self.length >= result.len);
            const unread_slice = self.unreadSlice();
            unread_slice.readAssumeCapacity(result);
            self.read_index = (self.read_index + result.len) % capacity;
            self.length -= result.len;
        }

        pub fn write(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.isFull())
                self.full.wait(&self.mutex);

            self.writeLockedAssumeCapacity(item);

            self.empty.notify(.one);
        }

        pub fn writeLockedAssumeCapacity(self: *Self, item: T) void {
            if (direction == .receive)
                @compileError("Cannot write to receive channel.");

            assert(!self.isFull());
            self.buffer[self.write_index] = item;
            self.write_index = (self.write_index + 1) % capacity;
            self.length += 1;
        }

        pub fn writeSlice(self: *Self, slice: []const T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var bytes_written: usize = 0;
            while (bytes_written < slice.len) {
                while (self.isFull())
                    self.full.wait(&self.mutex);

                const bytes_to_write = slice.len - bytes_written;
                const n = @min(self.freeLength(), bytes_to_write);
                self.writeSliceLockedAssumeCapacity(slice[bytes_written..][0..n]);
                bytes_written += n;

                self.empty.notify(.one);
            }
        }

        pub fn writeSliceLockedAssumeCapacity(self: *Self, slice: []const T) void {
            if (direction == .receive)
                @compileError("Cannot write to receive channel.");

            assert(self.freeLength() >= slice.len);
            var free_slice = self.freeSlice();
            free_slice.writeAssumeCapacity(slice);
            self.write_index = (self.write_index + slice.len) % capacity;
            self.length += slice.len;
        }

        pub fn unreadSlice(self: *Self) Slice {
            return self.sliceAt(self.read_index, self.length);
        }

        pub fn freeSlice(self: *Self) Slice {
            return self.sliceAt(self.write_index, self.freeLength());
        }

        pub fn sliceAt(self: *Self, index: usize, length: usize) Slice {
            assert(length <= capacity);
            const first_start = index % capacity;
            const first_end = @min(self.buffer.len, first_start + length);
            const first = self.buffer[first_start..first_end];
            const second = self.buffer[0 .. length - first.len];
            return .{
                .first = first,
                .second = second,
            };
        }

        pub const Slice = struct {
            first: []T,
            second: []T,

            pub fn length(self: Slice) usize {
                return self.first.len + self.second.len;
            }

            pub fn writeAssumeCapacity(self: *Slice, slice: []const T) void {
                assert(self.length() >= slice.len);
                const first_length = @min(self.first.len, slice.len);
                const second_length = slice.len - first_length;
                @memcpy(self.first.ptr, slice[0..first_length]);
                @memcpy(self.second.ptr, slice[first_length..][0..second_length]);
            }

            pub fn readAssumeCapacity(self: *const Slice, result: []T) void {
                assert(self.length() >= result.len);
                const first_length = @min(self.first.len, result.len);
                const second_length = result.len - first_length;
                @memcpy(result.ptr, self.first[0..first_length]);
                @memcpy(result[first_length..].ptr, self.second[0..second_length]);
            }

            pub fn iterator(self: *const Slice) Iterator {
                return .{
                    .slice = self,
                    .pos = 0,
                };
            }

            pub const Iterator = struct {
                slice: *const Slice,
                pos: usize,

                pub fn next(self: *Iterator) ?T {
                    defer self.pos += 1;
                    if (self.pos < self.slice.first.len) {
                        return self.slice.first[self.pos];
                    } else if (self.pos < self.slice.length()) {
                        return self.slice.second[self.pos - self.slice.first.len];
                    }
                    return null;
                }
            };
        };

        fn writeFn(context: *const anyopaque, buffer: []const u8) !usize {
            const self: *Self = @constCast(@alignCast(@ptrCast(context)));
            self.writeSlice(buffer);
            return buffer.len;
        }

        pub fn writer(self: *Self) AnyWriter {
            return .{
                .context = self,
                .writeFn = writeFn,
            };
        }

        pub fn readFn(context: *const anyopaque, buffer: []u8) !usize {
            const self: *Self = @constCast(@alignCast(@ptrCast(context)));
            self.readSlice(buffer);
            return buffer.len;
        }

        pub fn reader(self: *Self) AnyReader {
            return .{
                .context = self,
                .readFn = readFn,
            };
        }
    };
}
