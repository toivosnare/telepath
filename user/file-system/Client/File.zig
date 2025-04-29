const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const libt = @import("libt");
const service = libt.service;
const Channel = service.Channel;
const WaitEvent = libt.syscall.WaitEvent;
const main = @import("../main.zig");
const fcache = @import("../file_cache.zig");
const Client = @import("../Client.zig");
const File = @This();

region: *Region,
file: *fcache.Entry,
seek_offset: usize = 0,

pub const Request = service.File.Request;
pub const Response = service.File.Response;

const Region = extern struct {
    request: Channel(Request, service.File.channel_capacity, .receive),
    response: Channel(Response, service.File.channel_capacity, .transmit),
};

pub fn hasRequest(self: File, request_out: *Client.Request, wait_event: ?*WaitEvent) bool {
    const request_channel = &self.region.request;
    request_channel.mutex.lock();

    if (!request_channel.isEmpty()) {
        request_out.* = .{ .file = request_channel.readLockedAssumeCapacity() };
        request_channel.full.notify(.one);
        request_channel.mutex.unlock();
        return true;
    }

    const old_state = request_channel.empty.state.load(.monotonic);
    request_channel.mutex.unlock();

    if (wait_event) |we|
        we.payload = .{ .futex = .{
            .address = &request_channel.empty.state,
            .expected_value = old_state,
        } };

    return false;
}

pub fn handleRequest(self: *File, request: Request, allocator: Allocator) void {
    const payload: Response.Payload = switch (request.op) {
        .read => .{ .read = self.read(request.payload.read) },
        .write => .{ .write = self.write(request.payload.write) },
        .seek => .{ .seek = self.seek(request.payload.seek) },
        .close => .{ .close = self.close(request.payload.close) },
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

fn read(self: *File, request: Request.Read) usize {
    const bytes_written = self.file.read(self.seek_offset, request.handle, request.offset, request.n);
    self.seek_offset += bytes_written;
    return bytes_written;
}

fn write(self: *File, request: Request.Write) usize {
    const bytes_read = self.file.write(self.seek_offset, request.handle, request.offset, request.n);
    self.seek_offset += bytes_read;
    return bytes_read;
}

fn seek(self: *File, request: Request.Seek) isize {
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
        .end => if (math.cast(usize, @as(isize, @intCast(self.file.size)) - request.offset)) |offset| {
            self.seek_offset = offset;
        } else {
            return -1;
        },
    }

    return @intCast(self.seek_offset);
}

fn close(self: *File, request: Request.Close) void {
    _ = request;
    const client: *Client = @fieldParentPtr("kind", @as(*Client.Kind, @ptrCast(self)));
    main.removeClient(client);
}
