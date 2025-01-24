const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const libt = @import("libt");
const service = libt.service;
const WaitReason = libt.syscall.WaitReason;
const main = @import("../main.zig");
const fcache = @import("../file_cache.zig");
const Client = @import("../Client.zig");
const File = @This();

channel: *service.file.provide.Type,
file: *fcache.Entry,
seek_offset: usize = 0,

pub const Request = service.file.Request;
pub const Response = service.file.Response;

pub fn hasRequest(self: File, request_out: *Client.Request, wait_reason: ?*WaitReason) bool {
    const request_channel = &self.channel.request;
    request_channel.mutex.lock();

    if (!request_channel.isEmpty()) {
        request_out.* = .{ .file = request_channel.readLockedAssumeCapacity() };
        request_channel.full.notify(.one);
        request_channel.mutex.unlock();
        return true;
    }

    const old_state = request_channel.empty.state.load(.monotonic);
    request_channel.mutex.unlock();

    if (wait_reason) |wr|
        wr.payload = .{ .futex = .{
            .address = &self.channel.request.empty.state,
            .expected_value = old_state,
        } };

    return false;
}

pub fn handleRequest(self: *File, request: Request, allocator: Allocator) void {
    const payload: Response.Payload = switch (request.op) {
        .read => .{ .read = self.read(request.payload.read) },
        .seek => .{ .seek = self.seek(request.payload.seek) },
        .close => .{ .close = self.close(request.payload.close) },
    };
    self.channel.response.write(.{
        .token = request.token,
        .op = request.op,
        .payload = payload,
    });

    if (request.op == .close) {
        const client: *Client = @fieldParentPtr("kind", @as(*Client.Kind, @ptrCast(self)));
        allocator.destroy(client);
    }
}

pub fn read(self: *File, request: Request.Read) usize {
    const bytes_written = self.file.read(self.seek_offset, request.handle, request.offset, request.n);
    self.seek_offset += bytes_written;
    return bytes_written;
}

pub fn seek(self: *File, request: Request.Seek) isize {
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

pub fn close(self: *File, request: Request.Close) void {
    _ = request;
    const client: *Client = @fieldParentPtr("kind", @as(*Client.Kind, @ptrCast(self)));
    main.removeClient(client);
}
