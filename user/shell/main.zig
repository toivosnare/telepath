const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const libt = @import("libt");
const syscall = libt.syscall;
const services = @import("services");

comptime {
    _ = libt;
}

pub fn main(args: []usize) !void {
    _ = args;

    const serial = services.serial;
    const writer = serial.tx.writer();
    const reader = serial.rx.reader();
    const block = services.block;

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
            try read(&it, writer, block);
        } else if (mem.eql(u8, verb, "write")) {
            try write(&it, writer, block);
        } else if (mem.eql(u8, verb, "exit")) {
            break;
        } else {
            try writer.writeAll("Invalid commmand\n");
        }
    }
}

fn read(
    it: *mem.SplitIterator(u8, .scalar),
    writer: anytype,
    block: *libt.service.block_driver.consume.Type,
) !void {
    const sector_number_string = it.next() orelse {
        try writer.writeAll("Expected sector number\n");
        return;
    };
    const sector_number = fmt.parseInt(usize, sector_number_string, 0) catch {
        try writer.writeAll("Invalid sector number\n");
        return;
    };

    var sector: [512]u8 = undefined;
    const address = @intFromPtr(syscall.translate(&sector) catch unreachable);
    block.request.write(.{
        .sector = sector_number,
        .address = address,
        .write = false,
        .token = 0,
    });
    const response = services.block.response.read();
    assert(response.token == 0);

    if (response.success) {
        try hexdump(&sector, writer);
    } else {
        try writer.writeAll("Read failed\n");
    }
}

fn write(
    it: *mem.SplitIterator(u8, .scalar),
    writer: anytype,
    block: *libt.service.block_driver.consume.Type,
) !void {
    const sector_number_string = it.next() orelse {
        try writer.writeAll("Expected sector number\n");
        return;
    };
    const sector_number = fmt.parseInt(usize, sector_number_string, 0) catch {
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

    block.request.write(.{
        .sector = sector_number,
        .address = @intFromPtr(syscall.translate(&sector) catch unreachable),
        .write = true,
        .token = 0,
    });
    const response = services.block.response.read();
    assert(response.token == 0);

    if (!response.success)
        try writer.writeAll("Write failed\n");
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
