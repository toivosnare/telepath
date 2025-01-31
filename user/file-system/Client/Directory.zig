const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const libt = @import("libt");
const syscall = libt.syscall;
const service = libt.service;
const Channel = service.Channel;
const WaitReason = syscall.WaitReason;
const main = @import("../main.zig");
const fcache = @import("../file_cache.zig");
const scache = @import("../sector_cache.zig");
const Client = @import("../Client.zig");
const Directory = @This();

region: *Region,
root_directory: *fcache.Entry,
seek_offset: usize = 0,

pub const Request = service.Directory.Request;
pub const Response = service.Directory.Response;

const Region = extern struct {
    request: Channel(Request, service.Directory.channel_capacity, .receive),
    response: Channel(Response, service.Directory.channel_capacity, .transmit),
    buffer: [service.Directory.buffer_capacity]u8,
};

pub fn hasRequest(self: Directory, request_out: *Client.Request, wait_reason: ?*WaitReason) bool {
    const request_channel = &self.region.request;
    request_channel.mutex.lock();

    if (!request_channel.isEmpty()) {
        request_out.* = .{ .directory = request_channel.readLockedAssumeCapacity() };
        request_channel.full.notify(.one);
        request_channel.mutex.unlock();
        return true;
    }

    const old_state = request_channel.empty.state.load(.monotonic);
    request_channel.mutex.unlock();

    if (wait_reason) |wr|
        wr.payload = .{ .futex = .{
            .address = &request_channel.empty.state,
            .expected_value = old_state,
        } };

    return false;
}

pub fn handleRequest(self: *Directory, request: Request, allocator: Allocator) void {
    const payload: Response.Payload = switch (request.op) {
        .read => .{ .read = self.read(request.payload.read) },
        .seek => .{ .seek = self.seek(request.payload.seek) },
        .close => .{ .close = self.close(request.payload.close) },
        .open => .{ .open = if (self.open(request.payload.open, allocator)) true else |_| false },
        .stat => .{ .stat = if (self.stat(request.payload.stat)) true else |_| false },
        .sync => .{ .sync = self.sync(request.payload.sync) },
    };
    self.region.response.write(.{
        .token = request.token,
        .op = request.op,
        .payload = payload,
    });

    if (request.op == .close) {
        const client: *Client = @fieldParentPtr("kind", @as(*Client.Kind, @ptrCast(self)));
        allocator.destroy(client);
    }
}

fn read(self: *Directory, request: Request.Read) usize {
    return self.root_directory.readdir(&self.seek_offset, request.handle, request.offset, request.n);
}

fn seek(self: *Directory, request: Request.Seek) isize {
    switch (request.whence) {
        .set => if (math.cast(usize, request.offset)) |offset| {
            self.seek_offset = offset;
        } else {
            return -1;
        },
        .current => if (math.cast(usize, @as(isize, @intCast(self.seek_offset)) + request.offset)) |offset| {
            self.seek_offset = offset;
        } else {
            return -1;
        },
    }

    return @intCast(self.seek_offset);
}

fn close(self: *Directory, request: Request.Close) void {
    _ = request;
    const client: *Client = @fieldParentPtr("kind", @as(*Client.Kind, @ptrCast(self)));
    main.removeClient(client);
}

fn open(self: Directory, request: Request.Open, allocator: Allocator) !void {
    errdefer syscall.regionFree(.self, request.handle) catch {};

    if (request.path_offset + request.path_length > service.Directory.buffer_capacity)
        return error.InvalidParameter;
    if (request.path_length == 0)
        return error.InvalidParameter;
    const path = self.region.buffer[request.path_offset..][0..request.path_length];

    const entry = try self.root_directory.lookup(path);
    errdefer entry.unref();

    const needed_region_size_in_bytes: usize = if (entry.kind == .directory)
        @sizeOf(service.Directory)
    else
        @sizeOf(service.File);
    const needed_region_size = math.divCeil(usize, needed_region_size_in_bytes, mem.page_size) catch unreachable;
    const region_size = try syscall.regionSize(.self, request.handle);
    if (region_size < needed_region_size)
        return error.InvalidParameter;

    const region_ptr = try syscall.regionMap(.self, request.handle, null);
    errdefer _ = syscall.regionUnmap(.self, region_ptr) catch {};

    const new_client = try allocator.create(Client);
    new_client.* = if (entry.kind == .directory)
        .{ .kind = .{ .directory = .{
            .region = @ptrCast(region_ptr),
            .root_directory = entry,
        } } }
    else
        .{ .kind = .{ .file = .{
            .region = @ptrCast(region_ptr),
            .file = entry,
        } } };
    main.addClient(new_client);
}

fn stat(self: Directory, request: Request.Stat) !void {
    if (request.path_offset + request.path_length > service.Directory.buffer_capacity)
        return error.InvalidParameter;
    if (request.path_length == 0)
        return error.InvalidParameter;
    const path = self.region.buffer[request.path_offset..][0..request.path_length];

    const fentry = try self.root_directory.lookup(path);
    defer fentry.unref();

    try fentry.stat(request.region_handle, request.region_offset);
}

fn sync(self: Directory, request: Request.Sync) void {
    _ = self;
    _ = request;
    scache.sync();
}
