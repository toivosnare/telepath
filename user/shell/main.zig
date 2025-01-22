const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const math = std.math;
const libt = @import("libt");
const syscall = libt.syscall;
const Handle = libt.Handle;
const BlockDriver = libt.service.block_driver.consume.Type;
const FileSystem = libt.service.file_system.consume.Type;
const File = libt.service.file.consume.Type;
const services = @import("services");

comptime {
    _ = libt;
}

pub fn main(args: []usize) !void {
    const serial_driver = services.serial_driver;
    const writer = serial_driver.tx.writer();
    const reader = serial_driver.rx.reader();
    const block_driver = services.block_driver;
    const file_system = services.file_system;

    const file_system_handle: Handle = @enumFromInt(args[2]);
    if (file_system_handle == .self) {
        try writer.writeAll("Invalid file system handle\n");
        return error.InvalidHandle;
    }

    const command_max_length = 512;
    var command: [command_max_length]u8 = undefined;
    var command_stream = io.fixedBufferStream(&command);
    var command_writer = command_stream.writer();

    try writer.writeAll("Telepath shell\n");
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
            try read(&it, writer, block_driver);
        } else if (mem.eql(u8, verb, "write")) {
            try write(&it, writer, block_driver);
        } else if (mem.eql(u8, verb, "ls")) {
            try ls(&it, writer, file_system);
        } else if (mem.eql(u8, verb, "cat")) {
            try cat(&it, writer, file_system, file_system_handle);
        } else if (mem.eql(u8, verb, "exit")) {
            break;
        } else {
            try writer.writeAll("Invalid commmand\n");
        }
    }
}

fn read(it: *mem.SplitIterator(u8, .scalar), writer: anytype, block_driver: *BlockDriver) !void {
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

fn write(it: *mem.SplitIterator(u8, .scalar), writer: anytype, block_driver: *BlockDriver) !void {
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

fn ls(it: *mem.SplitIterator(u8, .scalar), writer: anytype, file_system: *FileSystem) !void {
    const path = it.next() orelse "/";
    const buffer: [*]u8 = @ptrCast(&file_system.buffer);
    @memcpy(buffer, path);

    file_system.request.write(.{
        .token = 0,
        .op = .read,
        .payload = .{ .read = .{
            .path_offset = 0,
            .path_length = path.len,
            .buffer_offset = 0,
            .n = 10,
        } },
    });
    const response = file_system.response.read();
    assert(response.token == 0);

    const n = response.payload.read;
    const DirectoryEntry = libt.service.file_system.DirectoryEntry;
    var entries: []DirectoryEntry = undefined;
    entries.ptr = @ptrCast(&file_system.buffer);
    entries.len = n;

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

fn cat(it: *mem.SplitIterator(u8, .scalar), writer: anytype, file_system: *FileSystem, file_system_handle: Handle) !void {
    const path = it.next() orelse return;
    const buffer: [*]u8 = @ptrCast(&file_system.buffer);
    @memcpy(buffer, path);

    const channel_size_in_bytes = @sizeOf(File);
    const channel_size = math.divCeil(usize, channel_size_in_bytes, mem.page_size) catch unreachable;

    const channel_handle = try syscall.regionAllocate(.self, channel_size, .{ .read = true, .write = true }, null);
    defer syscall.regionFree(.self, channel_handle) catch {};

    const shared_channel_handle = try syscall.regionShare(.self, channel_handle, file_system_handle, .{ .read = true, .write = true });

    file_system.request.write(.{
        .token = 0,
        .op = .open,
        .payload = .{ .open = .{
            .path_offset = 0,
            .path_length = path.len,
            .handle = shared_channel_handle,
        } },
    });
    const response = file_system.response.read();
    assert(response.token == 0);

    if (response.payload.open == false) {
        try writer.writeAll("Error\n");
        return;
    }

    const file: *File = @ptrCast(try syscall.regionMap(.self, channel_handle, null));
    defer _ = syscall.regionUnmap(.self, @alignCast(@ptrCast(file))) catch {};

    const buf_handle = try syscall.regionAllocate(.self, 1, .{ .read = true, .write = true }, null);
    defer syscall.regionFree(.self, buf_handle) catch {};

    const buf_ptr = try syscall.regionMap(.self, buf_handle, null);
    defer _ = syscall.regionUnmap(.self, buf_ptr) catch {};

    const shared_buf_handle = try syscall.regionShare(.self, buf_handle, file_system_handle, .{ .read = true, .write = true });

    var bytes_read: usize = 0;
    while (true) {
        file.request.write(.{
            .token = 0,
            .op = .read,
            .payload = .{ .read = .{
                .handle = shared_buf_handle,
                .offset = 0,
                .n = mem.page_size,
            } },
        });
        const file_response = file.response.read();
        assert(file_response.token == 0);
        const n = file_response.payload.read;

        if (n == 0)
            break;
        bytes_read += n;
    }

    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(buf_ptr);
    bytes.len = bytes_read;
    try writer.writeAll(bytes);
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
