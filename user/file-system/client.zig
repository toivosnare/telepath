const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const syscall = libt.syscall;
const service = libt.service;
const WaitReason = libt.syscall.WaitReason;
const fat = @import("fat.zig");
const main = @import("main.zig");
const fcache = @import("file_cache.zig");
const scache = @import("sector_cache.zig");
const Sector = scache.Sector;

pub const Client = union(enum) {
    directory: Directory,
    file: File,

    pub const Request = union(enum) {
        directory: Directory.Request,
        file: File.Request,
    };

    pub const Response = union(enum) {
        directory: Directory.Response,
        file: File.Response,
    };

    pub fn hasRequest(self: Client, request_out: *Request, wait_reason: ?*WaitReason) bool {
        return switch (self) {
            .directory => self.directory.hasRequest(request_out, wait_reason),
            .file => self.file.hasRequest(request_out, wait_reason),
        };
    }

    pub fn handleRequest(self: *Client, request: Request) void {
        switch (self.*) {
            .directory => self.directory.handleRequest(request.directory),
            .file => self.file.handleRequest(request.file),
        }
    }
};

pub const Directory = struct {
    channel: *service.file_system.provide.Type,
    root_directory: *fcache.Entry,
    seek_offset: usize = 0,

    pub const Request = service.file_system.Request;
    pub const Response = service.file_system.Response;

    pub fn hasRequest(self: Directory, request_out: *Client.Request, wait_reason: ?*WaitReason) bool {
        const request_channel = &self.channel.request;
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
                .address = &self.channel.request.empty.state,
                .expected_value = old_state,
            } };

        return false;
    }

    pub fn handleRequest(self: *Directory, request: Request) void {
        const payload: Response.Payload = switch (request.op) {
            .read => .{ .read = self.read(request.payload.read) },
            .open => .{ .open = if (self.open(request.payload.open)) true else |_| false },
        };
        self.channel.response.write(.{
            .token = request.token,
            .op = request.op,
            .payload = payload,
        });
    }

    pub fn read(self: *Directory, request: Request.Read) usize {
        return self.root_directory.readdir(&self.seek_offset, request.handle, request.offset, request.n);
    }

    pub fn open(self: Directory, request: Request.Open) !void {
        errdefer syscall.regionFree(.self, request.handle) catch {};

        if (request.path_offset + request.path_length > service.file_system.buffer_capacity)
            return error.InvalidParameter;
        if (request.path_length == 0)
            return error.InvalidParameter;
        const path = self.channel.buffer[request.path_offset..][0..request.path_length];

        const entry = try self.root_directory.lookup(path);
        errdefer entry.unref();

        const channel_size_in_bytes: usize = if (entry.kind == .directory)
            @sizeOf(service.file_system.provide.Type)
        else
            @sizeOf(service.file.provide.Type);
        const channel_size = math.divCeil(usize, channel_size_in_bytes, mem.page_size) catch unreachable;
        const region_size = try syscall.regionSize(.self, request.handle);
        if (region_size < channel_size)
            return error.InvalidParameter;

        const channel_ptr = try syscall.regionMap(.self, request.handle, null);
        errdefer _ = syscall.regionUnmap(.self, channel_ptr) catch {};

        const new_client = try main.addClient();
        new_client.* = if (entry.kind == .directory)
            .{ .directory = .{
                .channel = @ptrCast(channel_ptr),
                .root_directory = entry,
            } }
        else
            .{ .file = .{
                .channel = @ptrCast(channel_ptr),
                .file = entry,
            } };
    }
};

pub const File = struct {
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

    pub fn handleRequest(self: *File, request: Request) void {
        const payload: Response.Payload = switch (request.op) {
            .read => .{ .read = self.read(request.payload.read) },
        };
        self.channel.response.write(.{
            .token = request.token,
            .op = request.op,
            .payload = payload,
        });
    }

    pub fn read(self: *File, request: Request.Read) usize {
        const bytes_written = self.file.read(self.seek_offset, request.handle, request.offset, request.n);
        self.seek_offset += bytes_written;
        return bytes_written;
    }
};
