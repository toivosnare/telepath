const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const math = std.math;
const libt = @import("libt");
const service = libt.service;
const syscall = libt.syscall;
const Handle = libt.Handle;

pub const std_options = libt.std_options;

comptime {
    _ = libt;
}

extern var serial_driver: service.SerialDriver;
extern var block_driver: service.BlockDriver;
extern var root_directory: service.Directory;
extern var rtc_driver: service.RtcDriver;

const page_size = std.heap.pageSize();

pub fn main(args: []usize) !void {
    const writer = serial_driver.tx.writer();
    const reader = serial_driver.rx.reader();

    const file_system_handle: Handle = @enumFromInt(args[0]);
    if (file_system_handle == .self) {
        try writer.print("Invalid file system handle: {d}\n", .{args[0]});
        return error.InvalidHandle;
    }

    const buf_handle = try syscall.regionAllocate(.self, 1, .{ .read = true, .write = true }, null);
    defer syscall.regionFree(.self, buf_handle) catch {};

    const buf_ptr = try syscall.regionMap(.self, buf_handle, null);
    defer _ = syscall.regionUnmap(.self, buf_ptr) catch {};

    const shared_buf_handle = try syscall.regionShare(.self, buf_handle, file_system_handle, .{ .read = true, .write = true });

    const command_max_length = 512;
    var command: [command_max_length]u8 = undefined;
    var command_stream = io.fixedBufferStream(&command);
    var command_writer = command_stream.writer();

    const dt = rtc_driver.currentDateTime();
    try writer.writeAll("Telepath shell\nCurrent time is ");
    try writer.print("{:0>4}-{:0>2}-{:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.\n", .{
        dt.year,
        dt.month,
        dt.day,
        dt.hours,
        dt.minutes,
        dt.seconds,
    });
    while (true) {
        defer command_stream.reset();

        try writer.writeAll("# ");
        while (true) {
            const c = try reader.readByte();
            if (c == '\n' or c == '\r') {
                try writer.writeByte('\n');
                break;
            }
            try writer.writeByte(c);
            try command_writer.writeByte(c);
        }

        var it = mem.splitScalar(u8, command_stream.getWritten(), ' ');
        const verb = it.first();

        if (verb.len == 0) {
            continue;
        } else if (mem.eql(u8, verb, "echo")) {
            try writer.writeAll(it.rest());
            try writer.writeByte('\n');
        } else if (mem.eql(u8, verb, "read")) {
            try read(&it, writer);
        } else if (mem.eql(u8, verb, "write")) {
            try write(&it, writer);
        } else if (mem.eql(u8, verb, "ls")) {
            try ls(&it, writer, shared_buf_handle, buf_ptr, file_system_handle);
        } else if (mem.eql(u8, verb, "cat")) {
            try cat(&it, writer, shared_buf_handle, buf_ptr, file_system_handle);
        } else if (mem.eql(u8, verb, "sync")) {
            try sync(&it, writer);
        } else if (mem.eql(u8, verb, "exit")) {
            break;
        } else {
            try writer.writeAll("Invalid commmand\n");
        }
    }
}

fn read(it: *mem.SplitIterator(u8, .scalar), writer: anytype) !void {
    const sector_index_string = it.next() orelse {
        try writer.writeAll("Expected sector number\n");
        return;
    };
    const sector_index = fmt.parseInt(usize, sector_index_string, 0) catch {
        try writer.writeAll("Invalid sector number\n");
        return;
    };

    var sector: [512]u8 = undefined;
    const address = @intFromPtr(syscall.processTranslate(.self, &sector) catch unreachable);
    block_driver.request.write(.{
        .sector_index = sector_index,
        .address = address,
        .write = false,
        .token = 0,
    });
    const response = block_driver.response.read();
    assert(response.token == 0);

    if (response.success) {
        try hexdump(&sector, writer);
    } else {
        try writer.writeAll("Read failed\n");
    }
}

fn write(it: *mem.SplitIterator(u8, .scalar), writer: anytype) !void {
    const sector_index_string = it.next() orelse {
        try writer.writeAll("Expected sector number\n");
        return;
    };
    const sector_index = fmt.parseInt(usize, sector_index_string, 0) catch {
        try writer.writeAll("Invalid sector number\n");
        return;
    };

    const sector_size = 512;
    var sector: [sector_size]u8 = .{0} ** sector_size;
    var i: usize = 0;
    while (it.next()) |byte_string| : (i += 1) {
        if (i >= sector_size)
            break;

        sector[i] = fmt.parseInt(u8, byte_string, 0) catch {
            try writer.print("Invalid byte at index {d}\n", .{i});
            return;
        };
    }

    block_driver.request.write(.{
        .sector_index = sector_index,
        .address = @intFromPtr(syscall.processTranslate(.self, &sector) catch unreachable),
        .write = true,
        .token = 0,
    });
    const response = block_driver.response.read();
    assert(response.token == 0);

    if (!response.success)
        try writer.writeAll("Write failed\n");
}

fn ls(
    it: *mem.SplitIterator(u8, .scalar),
    writer: anytype,
    shared_buf_handle: Handle,
    buf_ptr: *align(page_size) anyopaque,
    file_system_handle: Handle,
) !void {
    const path = it.next() orelse "/";
    const directory = root_directory.openDirectory(path, file_system_handle) catch {
        try writer.writeAll("Error\n");
        return;
    };
    defer directory.closeDirectory();

    var entries_read: usize = 0;
    while (true) {
        const entries_to_read = page_size / @sizeOf(service.Directory.Entry) - entries_read;
        const n = directory.read(shared_buf_handle, entries_read, entries_to_read);
        if (n == 0)
            break;
        entries_read += n;
    }

    var entries: []service.Directory.Entry = undefined;
    entries.ptr = @ptrCast(buf_ptr);
    entries.len = entries_read;

    for (entries) |entry| {
        if (entry.flags.directory) {
            try writer.writeAll(" <DIR>");
        } else {
            try writer.print(" {d: >5}", .{entry.size});
        }
        try writer.print(" {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}\n", .{
            entry.modification_time.year,
            entry.modification_time.month,
            entry.modification_time.day,
            entry.modification_time.hours,
            entry.modification_time.minutes,
            entry.modification_time.seconds,
            entry.name[0..entry.name_length],
        });
    }
}

fn cat(
    it: *mem.SplitIterator(u8, .scalar),
    writer: anytype,
    shared_buf_handle: Handle,
    buf_ptr: *align(page_size) anyopaque,
    file_system_handle: Handle,
) !void {
    const path = it.next() orelse return;
    const file = root_directory.openFile(path, file_system_handle) catch {
        try writer.writeAll("Error\n");
        return;
    };
    defer file.closeFile();

    var bytes_read: usize = 0;
    while (true) {
        const bytes_to_read = page_size - bytes_read;
        const n = file.read(shared_buf_handle, bytes_read, bytes_to_read);
        if (n == 0)
            break;
        bytes_read += n;
    }

    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(buf_ptr);
    bytes.len = bytes_read;
    try writer.writeAll(bytes);
}

fn sync(
    it: *mem.SplitIterator(u8, .scalar),
    writer: anytype,
) !void {
    _ = it;
    _ = writer;
    root_directory.sync();
}

fn hexdump(bytes: []const u8, writer: anytype) !void {
    var bw = io.bufferedWriter(writer);
    const buffered_writer = bw.writer();

    const row_length = 16;
    var it = mem.window(u8, bytes, row_length, row_length);
    var offset: usize = 0;

    while (it.next()) |row| : (offset += row_length) {
        try buffered_writer.print("{x:0>8}  ", .{offset});
        for (row) |byte| {
            try buffered_writer.print("{x:0>2} ", .{byte});
        }
        try buffered_writer.writeAll(" |");
        for (row) |byte| {
            if (std.ascii.isPrint(byte)) {
                try buffered_writer.print("{c}", .{byte});
            } else {
                try buffered_writer.writeByte('.');
            }
        }
        try buffered_writer.writeAll("|\n");
    }
    try bw.flush();
}
