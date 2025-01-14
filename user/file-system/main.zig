const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const file_system = libt.service.file_system;
const Request = file_system.Request;
const Response = file_system.Response;
const syscall = libt.syscall;
const cache = @import("cache.zig");
const fat = @import("fat.zig");
const services = @import("services");

pub const os = libt;
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

comptime {
    _ = libt;
}

const writer = services.serial.tx.writer();

const Client = struct {
    channel: *file_system.provide.Type,
    root_directory_sector: usize = undefined,
    working_directory_sector: usize = undefined,
};

const MasterBootRecord = extern struct {
    bootstrap_code: [446]u8,
    partitions: [4]PartitionEntry align(1),
    boot_signature: [2]u8,

    pub const PartitionEntry = extern struct {
        status: packed struct(u8) {
            _: u7,
            active: bool,
        },
        chs_first: [3]u8,
        partition_type: enum(u8) {
            fat16 = 0x06,
            _,
        },
        chs_last: [3]u8,
        lba_first: u32 align(1),
        number_of_sectors: u32 align(1),

        comptime {
            assert(@sizeOf(PartitionEntry) == 16);
        }
    };

    pub const boot_signature: [2]u8 = .{ 0x55, 0xAA };

    comptime {
        assert(@sizeOf(MasterBootRecord) == 512);
    }
};

const sector_size = 512;

fn readSector(sector_index: usize, buf: *[sector_size]u8) !void {
    const physical_address = try syscall.processTranslate(.self, buf);
    services.block.request.write(.{
        .sector_index = sector_index,
        .address = @intFromPtr(physical_address),
        .write = false,
        .token = 0,
    });
    const response = services.block.response.read();
    if (!response.success)
        return error.Failed;
}

pub fn main(args: []usize) !void {
    _ = args;
    try writer.writeAll("Initializing file system.\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .MutexType = libt.sync.Mutex,
    }){};
    const allocator = gpa.allocator();

    const sector_buf = try allocator.alloc(u8, sector_size);

    try readSector(0, @ptrCast(sector_buf.ptr));
    const mbr: *const MasterBootRecord = @ptrCast(sector_buf.ptr);
    if (!mem.eql(u8, &mbr.boot_signature, &MasterBootRecord.boot_signature)) {
        try writer.writeAll("Invalid MBR boot signature.\n");
        return error.InvalidBootSignature;
    }

    const partition = for (&mbr.partitions) |*partition| {
        if (partition.status.active and partition.partition_type == .fat16)
            break partition;
    } else {
        try writer.writeAll("Could not find valid partition.\n");
        return error.NoValidPartition;
    };

    const vbr_sector = partition.lba_first;
    try readSector(vbr_sector, @ptrCast(sector_buf.ptr));
    const root_directory_sector = fat.init(vbr_sector, @ptrCast(sector_buf.ptr));
    allocator.free(sector_buf);

    var clients = ArrayList(Client).init(allocator);
    try clients.append(.{
        .channel = services.client,
        .root_directory_sector = root_directory_sector,
        .working_directory_sector = root_directory_sector,
    });

    // Allocate and map a stack for the worker thread.
    const stack_pages = 16;
    const stack_handle = try syscall.regionAllocate(.self, stack_pages, .{ .read = true, .write = true }, null);
    const stack_start: [*]align(mem.page_size) u8 = @ptrCast(try syscall.regionMap(.self, stack_handle, null));
    const stack_end = stack_start + stack_pages * mem.page_size;

    const worker_handle = try syscall.threadAllocate(.self, .self, &worker, stack_end, @intFromPtr(&clients), 0);
    _ = worker_handle;

    cache.init();
    cache.loop();
}

fn worker(clients: *ArrayList(Client)) void {
    log.info("worker running", .{});
    while (true) {
        const client = &clients.items[0];
        const request = client.channel.request.read();
        const payload: Response.Payload = switch (request.op) {
            .read => .{ .read = read(client, request.payload.read) },
            .change_working_directory => .{ .change_working_directory = changeWorkingDirectory(client, request.payload.change_working_directory) },
        };
        client.channel.response.write(.{
            .token = request.token,
            .op = request.op,
            .payload = payload,
        });
    }
}

fn read(client: *Client, request: Request.Read) Response.Read {
    var file_name_buf: [file_system.DirectoryEntry.name_capacity]u8 = undefined;
    var it = fat.DirectoryEntry.Iterator.init(client.working_directory_sector);
    var directory_entries: [*]file_system.DirectoryEntry = @alignCast(@ptrCast(&client.channel.buffer[request.buffer_offset]));
    var n: usize = 0;

    while (n < request.n) : (n += 1) {
        var file_name_slice: []u8 = &file_name_buf;
        const fat_directory_entry: *fat.DirectoryEntry.Normal = it.next(&file_name_slice) orelse break;
        const directory_entry: *file_system.DirectoryEntry = &directory_entries[n];

        @memcpy(directory_entry.name[0..file_name_slice.len], file_name_slice);
        directory_entry.name_length = @intCast(file_name_slice.len);
        directory_entry.flags.directory = fat_directory_entry.attributes.directory;

        directory_entry.creation_time.year = @as(u16, 1980) + fat_directory_entry.creation_date.year;
        directory_entry.creation_time.month = fat_directory_entry.creation_date.month;
        directory_entry.creation_time.day = fat_directory_entry.creation_date.day;
        directory_entry.creation_time.hours = fat_directory_entry.creation_time.hour;
        directory_entry.creation_time.minutes = fat_directory_entry.creation_time.minute;
        directory_entry.creation_time.seconds = @as(u8, 2) * fat_directory_entry.creation_time.second;
        if (fat_directory_entry.creation_time_cs >= 100)
            directory_entry.creation_time.seconds += 1;

        directory_entry.access_time.year = @as(u16, 1980) + fat_directory_entry.access_date.year;
        directory_entry.access_time.month = fat_directory_entry.access_date.month;
        directory_entry.access_time.day = fat_directory_entry.access_date.day;
        directory_entry.access_time.hours = 0;
        directory_entry.access_time.minutes = 0;
        directory_entry.access_time.seconds = 0;

        directory_entry.modification_time.year = @as(u16, 1980) + fat_directory_entry.modification_date.year;
        directory_entry.modification_time.month = fat_directory_entry.modification_date.month;
        directory_entry.modification_time.day = fat_directory_entry.modification_date.day;
        directory_entry.modification_time.hours = fat_directory_entry.modification_time.hour;
        directory_entry.modification_time.minutes = fat_directory_entry.modification_time.minute;
        directory_entry.modification_time.seconds = @as(u8, 2) * fat_directory_entry.modification_time.second;

        directory_entry.size = fat_directory_entry.size;
    }

    return n;
}

fn changeWorkingDirectory(client: *Client, request: Request.ChangeWorkingDirectory) Response.ChangeWorkingDirectory {
    if (request.path_offset + request.path_length > file_system.buffer_capacity)
        return -1;
    if (request.path_length == 0) {
        client.working_directory_sector = client.root_directory_sector;
        return 0;
    }

    const path = client.channel.buffer[request.path_offset..][0..request.path_length];
    const path_is_absolute = path[0] == '/';
    var path_it = mem.tokenizeScalar(u8, path, '/');

    var start_sector = if (path_is_absolute) client.root_directory_sector else client.working_directory_sector;
    var dir_it = fat.DirectoryEntry.Iterator.init(start_sector);

    var file_name_buf: [file_system.DirectoryEntry.name_capacity]u8 = undefined;
    var file_name_slice: []u8 = &file_name_buf;

    while (path_it.next()) |path_part| {
        while (dir_it.next(&file_name_slice)) |directory_entry| : (file_name_slice = &file_name_buf) {
            if (mem.eql(u8, file_name_slice, path_part)) {
                if (!directory_entry.attributes.directory)
                    return -3;
                start_sector = if (directory_entry.cluster_number_low == 0)
                    client.root_directory_sector
                else
                    fat.sectorFromCluster(directory_entry.cluster_number_low);
                dir_it = fat.DirectoryEntry.Iterator.init(start_sector);
                break;
            }
        } else return -2;
    }

    client.working_directory_sector = start_sector;
    return 0;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = "[" ++ comptime level.asText() ++ "] ";
    writer.print(prefix ++ format ++ "\n", args) catch return;
}
