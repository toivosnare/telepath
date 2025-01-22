const std = @import("std");
const log = std.log;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const service = libt.service;
const syscall = libt.syscall;
const WaitReason = syscall.WaitReason;
const scache = @import("sector_cache.zig");
const Sector = scache.Sector;
const fcache = @import("file_cache.zig");
const fat = @import("fat.zig");
const Client = @import("client.zig").Client;
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

    try readSector(.mbr, @ptrCast(sector_buf.ptr));
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

    const vbr_sector: Sector = @enumFromInt(partition.lba_first);
    try readSector(vbr_sector, @ptrCast(sector_buf.ptr));
    const root_directory_sector = fat.init(vbr_sector, @ptrCast(sector_buf.ptr));
    allocator.free(sector_buf);

    clients = ArrayList(Client).init(allocator);
    const root_fcache_entry = fcache.init(root_directory_sector);

    try clients.append(.{ .directory = .{
        .channel = services.client,
        .root_directory = root_fcache_entry,
    } });
    scache.init();

    // Allocate and map a stack for the worker thread.
    const stack_pages = 16;
    const stack_handle = try syscall.regionAllocate(.self, stack_pages, .{ .read = true, .write = true }, null);
    const stack_start: [*]align(mem.page_size) u8 = @ptrCast(try syscall.regionMap(.self, stack_handle, null));
    const stack_end = stack_start + stack_pages * mem.page_size;

    const worker_handle = try syscall.threadAllocate(.self, .self, &worker, stack_end, 0, 0, 0);
    _ = worker_handle;

    scache.loop();
}

fn readSector(sector: Sector, buf: *[sector_size]u8) !void {
    const physical_address = try syscall.processTranslate(.self, buf);
    services.block.request.write(.{
        .sector_index = @intFromEnum(sector),
        .address = @intFromPtr(physical_address),
        .write = false,
        .token = 0,
    });
    const response = services.block.response.read();
    if (!response.success)
        return error.Failed;
}

fn worker() void {
    while (true) {
        var request: Client.Request = undefined;
        var client: *Client = undefined;
        getRequest(&request, &client);
        client.handleRequest(request);
    }
}

fn getRequest(request_out: *Client.Request, client_out: **Client) void {
    const wait_reasons = clients.allocator.alloc(WaitReason, clients.items.len) catch @panic("OOM");
    defer clients.allocator.free(wait_reasons);

    while (true) {
        for (clients.items, wait_reasons) |*client, *wait_reason| {
            if (client.hasRequest(request_out, wait_reason)) {
                client_out.* = client;
                return;
            }
            wait_reason.tag = .futex;
            wait_reason.result = 0;
        }

        const client_index = syscall.wait(wait_reasons, math.maxInt(usize)) catch @panic("wait error");
        syscall.unpackResult(syscall.WaitError!void, wait_reasons[client_index].result) catch |err| switch (err) {
            error.WouldBlock => {},
            else => @panic("wait error"),
        };

        const client = &clients.items[client_index];
        if (client.hasRequest(request_out, null)) {
            client_out.* = client;
            return;
        }
    }
}

pub fn addClient() !*Client {
    return clients.addOne();
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.err("PANIC: {s}", .{msg});
    while (true) {}
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
