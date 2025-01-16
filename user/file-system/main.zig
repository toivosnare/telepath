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
const WaitReason = syscall.WaitReason;
const cache = @import("cache.zig");
const fat = @import("fat.zig");
const Client = @import("Client.zig");
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
var clients: ArrayList(Client) = undefined;

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

    clients = ArrayList(Client).init(allocator);
    try clients.append(.{
        .channel = services.client,
        .root_directory = .{ .sector_index = root_directory_sector },
        .working_directory = .{ .sector_index = root_directory_sector },
    });

    // Allocate and map a stack for the worker thread.
    const stack_pages = 16;
    const stack_handle = try syscall.regionAllocate(.self, stack_pages, .{ .read = true, .write = true }, null);
    const stack_start: [*]align(mem.page_size) u8 = @ptrCast(try syscall.regionMap(.self, stack_handle, null));
    const stack_end = stack_start + stack_pages * mem.page_size;

    const worker_handle = try syscall.threadAllocate(.self, .self, &worker, stack_end, 0, 0, 0);
    _ = worker_handle;

    cache.init();
    cache.loop();
}

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

fn worker() void {
    log.info("worker running", .{});
    while (true) {
        var request: Request = undefined;
        var client: *Client = undefined;
        getRequest(&request, &client);
        const payload: Response.Payload = switch (request.op) {
            .read => .{ .read = read(client, request.payload.read) },
            .change_working_directory => .{ .change_working_directory = changeWorkingDirectory(client, request.payload.change_working_directory) },
            .open => .{ .open = open(client, request.payload.open) },
        };
        client.channel.response.write(.{
            .token = request.token,
            .op = request.op,
            .payload = payload,
        });
    }
}

fn getRequest(request_out: *Request, client_out: **Client) void {
    const wait_reasons = clients.allocator.alloc(WaitReason, clients.items.len) catch @panic("OOM");
    defer clients.allocator.free(wait_reasons);

    while (true) {
        for (wait_reasons, clients.items) |*wait_reason, *client| {
            const request_channel = &client.channel.request;
            request_channel.mutex.lock();

            if (!request_channel.isEmpty()) {
                request_out.* = request_channel.readLockedAssumeCapacity();
                client_out.* = client;
                request_channel.full.notify(.one);
                request_channel.mutex.unlock();
                return;
            }

            const old_state = request_channel.empty.state.load(.monotonic);
            request_channel.mutex.unlock();

            wait_reason.tag = .futex;
            wait_reason.result = 0;
            wait_reason.payload = .{ .futex = .{
                .address = &client.channel.request.empty.state,
                .expected_value = old_state,
            } };
        }

        const client_index = syscall.wait(wait_reasons, math.maxInt(usize)) catch @panic("wait error");
        syscall.unpackResult(syscall.WaitError!void, wait_reasons[client_index].result) catch |err| switch (err) {
            error.WouldBlock => {},
            else => @panic("wait error"),
        };
        const client = &clients.items[client_index];
        const request_channel = &client.channel.request;
        request_channel.mutex.lock();
        defer request_channel.mutex.unlock();

        if (!request_channel.isEmpty()) {
            request_out.* = request_channel.readLockedAssumeCapacity();
            client_out.* = client;
            request_channel.full.notify(.one);
            return;
        }
    }
}

fn read(client: *Client, request: Request.Read) Response.Read {
    const directory_entries_start: [*]file_system.DirectoryEntry = @alignCast(@ptrCast(&client.channel.buffer[request.buffer_offset]));
    const directory_entries = directory_entries_start[0..request.n];
    return client.read(directory_entries);
}

fn changeWorkingDirectory(client: *Client, request: Request.ChangeWorkingDirectory) Response.ChangeWorkingDirectory {
    if (request.path_offset + request.path_length > file_system.buffer_capacity)
        return -1;
    const path = client.channel.buffer[request.path_offset..][0..request.path_length];
    client.changeWorkingDirectory(path) catch return -2;
    return 0;
}

fn open(client: *Client, request: Request.Open) Response.Open {
    // TODO: These functions should return errors instead of negative integers.
    // errdefer syscall.regionFree(.self, request.handle) catch {};

    if (request.path_offset + request.path_length > file_system.buffer_capacity)
        return -1;
    if (request.path_length == 0)
        return -2;
    const path = client.channel.buffer[request.path_offset..][0..request.path_length];

    const lookup_result = client.open(path) catch return -3;
    if (lookup_result != .directory)
        return -4;

    const channel_size = math.divCeil(usize, @sizeOf(file_system.provide.Type), mem.page_size) catch unreachable;
    const region_size = syscall.regionSize(.self, request.handle) catch return -5;
    if (region_size < channel_size)
        return -6;

    const new_client = clients.addOne() catch return -7;
    const channel_ptr = syscall.regionMap(.self, request.handle, null) catch return -8;
    new_client.* = .{
        .channel = @ptrCast(channel_ptr),
        .root_directory = lookup_result.directory,
        .working_directory = lookup_result.directory,
    };

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
