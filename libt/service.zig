const std = @import("std");
const math = std.math;
const atomic = std.atomic;
const assert = std.debug.assert;
const io = std.io;
const AnyWriter = io.AnyWriter;
const AnyReader = io.AnyReader;
const Keccak = std.crypto.hash.sha3.Keccak(1600, 32, 0x06, 24);
const libt = @import("root.zig");
const Mutex = libt.sync.Mutex;
const Condvar = libt.sync.Condvar;
const Spinlock = libt.sync.Spinlock;
const Handle = libt.Handle;
const syscall = libt.syscall;

pub const SerialDriver = @import("service/serial_driver.zig").SerialDriver;
pub const RtcDriver = @import("service/rtc_driver.zig").RtcDriver;
pub const BlockDriver = @import("service/block_driver.zig").BlockDriver;
pub const Directory = @import("service/directory.zig").Directory;
pub const File = @import("service/file.zig").File;

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

pub fn Fifo(
    comptime T: type,
    comptime cap: comptime_int,
    comptime mw: bool,
    comptime mr: bool,
    comptime dir: enum { write_only, read_only, read_write },
) type {
    if (!math.isPowerOfTwo(cap))
        @compileError("Fifo capacity must be a power of two");

    return extern struct {
        write_index: atomic.Value(u32),
        read_index: atomic.Value(u32),
        buffer: [capacity]Element,
        write_lock: if (multi_writer) Spinlock else void,
        read_lock: if (multi_reader) Spinlock else void,

        pub const Element = T;
        pub const capacity = cap;
        pub const multi_writer = mw;
        pub const multi_reader = mr;
        pub const direction = dir;
        const Self = @This();

        pub fn length(self: *Self) u32 {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            return w -% r;
        }

        pub fn freeLength(self: *Self) u32 {
            return capacity - self.length();
        }

        pub fn tryWrite(self: *Self, e: Element) bool {
            if (direction == .read_only)
                @compileError("Cannot write to read only Fifo.");

            if (multi_writer) self.write_lock.lock();
            defer if (multi_writer) self.write_lock.unlock();

            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            const len = w -% r;

            if (len == capacity)
                return false;

            self.buffer[w % capacity] = e;
            self.write_index.store(w +% 1, .release);
            _ = libt.wake(&self.write_index, 1) catch unreachable;
            return true;
        }

        pub fn write(self: *Self, e: Element) void {
            if (direction == .read_only)
                @compileError("Cannot write to read only Fifo.");

            if (multi_writer) self.write_lock.lock();
            defer if (multi_writer) self.write_lock.unlock();

            while (true) {
                const w = self.write_index.load(.acquire);
                const r = self.read_index.load(.acquire);
                const len = w -% r;

                if (len < capacity) {
                    self.buffer[w % capacity] = e;
                    self.write_index.store(w +% 1, .release);
                    _ = libt.wake(&self.write_index, 1) catch unreachable;
                    break;
                }

                if (multi_writer) self.write_lock.unlock();
                libt.waitFutex(&self.read_index, r, null) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => unreachable,
                };
                if (multi_writer) self.write_lock.lock();
            }
        }

        pub fn writeSlice(self: *Self, e: []const Element) void {
            if (direction == .read_only)
                @compileError("Cannot write to read only Fifo.");

            if (multi_writer) self.write_lock.lock();
            defer if (multi_writer) self.write_lock.unlock();

            var to_write: []const Element = e;
            while (to_write.len > 0) {
                const w = self.write_index.load(.acquire);
                const r = self.read_index.load(.acquire);
                const len = w -% r;
                const free_len = capacity - len;

                if (free_len == 0) {
                    if (multi_writer) self.write_lock.unlock();
                    libt.waitFutex(&self.read_index, r, null) catch |err| switch (err) {
                        error.WouldBlock => {},
                        else => unreachable,
                    };
                    if (multi_writer) self.write_lock.lock();
                    continue;
                }

                const iteration_len = @min(to_write.len, free_len);
                const to_end_len = capacity - (w % capacity);

                const first_part_len = @min(to_end_len, iteration_len);
                const second_part_len = iteration_len - first_part_len;

                @memcpy(self.buffer[w % capacity ..][0..first_part_len], to_write[0..first_part_len]);
                @memcpy(self.buffer[0..second_part_len], to_write[first_part_len..][0..second_part_len]);

                self.write_index.store(w +% iteration_len, .release);
                _ = libt.wake(&self.write_index, 1) catch unreachable;

                to_write = to_write[iteration_len..];
            }
        }

        pub fn tryRead(self: *Self, e: *Element) bool {
            if (direction == .write_only)
                @compileError("Cannot read from write only Fifo.");

            if (multi_reader) self.read_lock.lock();
            defer if (multi_reader) self.read_lock.unlock();

            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            const len = w -% r;

            if (len == 0)
                return false;

            e.* = self.buffer[r % capacity];
            self.read_index.store(r +% 1, .release);
            _ = libt.wake(&self.read_index, 1) catch unreachable;
            return true;
        }

        pub fn read(self: *Self, e: *Element) void {
            if (direction == .write_only)
                @compileError("Cannot read from write only Fifo.");

            if (multi_reader) self.read_lock.lock();
            defer if (multi_reader) self.read_lock.unlock();

            while (true) {
                const w = self.write_index.load(.acquire);
                const r = self.read_index.load(.acquire);
                const len = w -% r;

                if (len > 0) {
                    e.* = self.buffer[r % capacity];
                    self.read_index.store(r +% 1, .release);
                    _ = libt.wake(&self.read_index, 1) catch unreachable;
                    break;
                }

                if (multi_reader) self.read_lock.unlock();
                libt.waitFutex(&self.write_index, w, null) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => unreachable,
                };
                if (multi_reader) self.read_lock.lock();
            }
        }

        pub fn readSlice(self: *Self, e: []Element) void {
            if (direction == .write_only)
                @compileError("Cannot read from write only Fifo.");

            if (multi_reader) self.read_lock.lock();
            defer if (multi_reader) self.read_lock.unlock();

            var to_read: []Element = e;
            while (to_read.len > 0) {
                const w = self.write_index.load(.acquire);
                const r = self.read_index.load(.acquire);
                const len = w -% r;

                if (len == 0) {
                    if (multi_reader) self.read_lock.unlock();
                    libt.waitFutex(&self.write_index, w, null) catch |err| switch (err) {
                        error.WouldBlock => {},
                        else => unreachable,
                    };
                    if (multi_reader) self.read_lock.lock();
                    continue;
                }

                const iteration_len = @min(to_read.len, len);
                const to_end_len = capacity - (r % capacity);

                const first_part_len = @min(to_end_len, iteration_len);
                const second_part_len = iteration_len - first_part_len;

                @memcpy(to_read[0..first_part_len], self.buffer[r % capacity ..][0..first_part_len]);
                @memcpy(to_read[first_part_len..][0..second_part_len], self.buffer[0..second_part_len]);

                self.read_index.store(r +% iteration_len, .release);
                _ = libt.wake(&self.read_index, 1) catch unreachable;

                to_read = to_read[iteration_len..];
            }
        }

        pub fn getNextWriteElement(self: *Self) ?*Element {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            const len = w -% r;
            if (len == capacity)
                return null;
            return &self.buffer[w % capacity];
        }

        pub fn getNextReadElement(self: *Self) ?*Element {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            const len = w -% r;
            if (len == 0)
                return null;
            return &self.buffer[r % capacity];
        }

        pub fn getReadSlice(self: *Self) Slice {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            const len = w -% r;
            return self.getSliceAt(r, len);
        }

        pub fn getWriteSlice(self: *Self) Slice {
            const w = self.write_index.load(.acquire);
            const r = self.read_index.load(.acquire);
            const len = w -% r;
            const free_len = capacity - len;
            return self.getSliceAt(w, free_len);
        }

        pub fn advanceWrite(self: *Self, len: u32) void {
            const w = self.write_index.load(.acquire);
            self.write_index.store(w +% len, .release);
            _ = libt.wake(&self.write_index, 1) catch unreachable;
        }

        pub fn advanceRead(self: *Self, len: u32) void {
            const r = self.read_index.load(.acquire);
            self.read_index.store(r +% len, .release);
            _ = libt.wake(&self.read_index, 1) catch unreachable;
        }

        pub fn getSliceAt(self: *Self, index: u32, len: u32) Slice {
            assert(len <= capacity);
            const first_part_start = index % capacity;
            const first_part_end = @min(self.buffer.len, first_part_start + len);
            const first_part = self.buffer[first_part_start..first_part_end];
            const second_part = self.buffer[0 .. len - first_part.len];
            return .{
                .first_part = first_part,
                .second_part = second_part,
            };
        }

        pub const Slice = struct {
            first_part: []Element,
            second_part: []Element,

            pub fn length(self: Slice) u32 {
                return @intCast(self.first_part.len + self.second_part.len);
            }

            pub fn writeAssumeCapacity(self: *Slice, e: []const Element) void {
                assert(self.length() >= e.len);
                const first_part_len = @min(self.first_part.len, e.len);
                const second_part_len = e.len - first_part_len;
                @memcpy(self.first_part.ptr, e[0..first_part_len]);
                @memcpy(self.second_part.ptr, e[first_part_len..][0..second_part_len]);
            }

            pub fn readAssumeCapacity(self: *const Slice, e: []Element) void {
                assert(self.length() <= e.len);
                const first_part_len = @min(self.first_part.len, e.len);
                const second_part_len = e.len - first_part_len;
                @memcpy(e.ptr, self.first_part[0..first_part_len]);
                @memcpy(e[first_part_len..].ptr, self.second_part[0..second_part_len]);
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

                pub fn next(self: *Iterator) ?Element {
                    defer self.pos += 1;
                    if (self.pos < self.slice.first_part.len) {
                        return self.slice.first_part[self.pos];
                    } else if (self.pos < self.slice.length()) {
                        return self.slice.second_part[self.pos - self.slice.first_part.len];
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
            if (Element != u8)
                @compileError("Writer only supported for u8 Element type.");
            return .{
                .context = self,
                .writeFn = writeFn,
            };
        }

        fn readFn(context: *const anyopaque, buffer: []u8) !usize {
            const self: *Self = @constCast(@alignCast(@ptrCast(context)));
            self.readSlice(buffer);
            return buffer.len;
        }

        pub fn reader(self: *Self) AnyReader {
            if (Element != u8)
                @compileError("Reader only supported for u8 Element type.");
            return .{
                .context = self,
                .readFn = readFn,
            };
        }
    };
}

pub const SpinConfig = union(enum) {
    constant: usize,
    adaptive: struct {
        spin_max: isize,
        spin_estimate_initial: isize,
        spin_estimate_refinement_rate: isize = 8,
    },

    pub const none: SpinConfig = .{ .constant = 0 };
};
pub fn Rpc(Req: type, Res: type, spin_config: SpinConfig) type {
    return extern struct {
        turn: atomic.Value(Turn),
        request: Request,
        response: Response,
        spin_estimate: if (spin_config == .adaptive) isize else void,

        pub const Request = Req;
        pub const Response = Res;
        pub const Turn = enum(u32) {
            client = 0,
            server = 1,
        };
        const Self = @This();

        pub fn init(self: *Self) void {
            self.turn.store(.client, .release);
            if (spin_config == .adaptive) {
                self.spin_estimate = spin_config.adaptive.spin_estimate_initial;
            }
        }

        pub fn call(self: *Self) void {
            self.turn.store(.server, .release);

            var spin_count: if (spin_config == .constant) usize else isize = 0;
            const spin_limit = switch (spin_config) {
                .constant => |constant| constant,
                .adaptive => |adaptive| @min(2 * self.spin_estimate, adaptive.spin_max),
            };
            defer {
                if (spin_config == .adaptive)
                    self.spin_estimate += @divTrunc(spin_count - self.spin_estimate, spin_config.adaptive.spin_estimate_refinement_rate);
            }
            while (spin_count < spin_limit) : (spin_count += 1) {
                if (self.turn.load(.acquire) == .client)
                    return;
            }

            while (self.turn.load(.acquire) != .client) {
                _ = libt.call(@ptrCast(&self.turn), @ptrCast(&self.turn), @intFromEnum(Turn.server), null) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => unreachable,
                };
            }
        }

        pub fn wait(self: *Self) void {
            var turn = self.turn.load(.acquire);
            while (turn != .server) {
                _ = libt.call(@ptrCast(&self.turn), @ptrCast(&self.turn), @intFromEnum(turn), null) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => unreachable,
                };
                turn = self.turn.load(.acquire);
            }
        }

        pub fn serve(self: *Self, handler: *const fn () bool) void {
            while (true) {
                self.wait();
                if (handler())
                    break;
                self.turn.store(.client, .release);
            }
        }
    };
}
