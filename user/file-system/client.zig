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
    root_directory: fat.Directory = undefined,
    working_directory: fat.Directory = undefined,

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
            .change_working_directory => .{ .change_working_directory = if (self.changeWorkingDirectory(request.payload.change_working_directory)) true else |_| false },
            .open => .{ .open = if (self.open(request.payload.open)) true else |_| false },
        };
        self.channel.response.write(.{
            .token = request.token,
            .op = request.op,
            .payload = payload,
        });
    }

    pub fn read(self: Directory, request: Request.Read) usize {
        const directory_entries_start: [*]service.file_system.DirectoryEntry = @alignCast(@ptrCast(&self.channel.buffer[request.buffer_offset]));
        const directory_entries = directory_entries_start[0..request.n];

        var file_name_buf: [service.file_system.DirectoryEntry.name_capacity]u8 = undefined;
        var it = self.working_directory.iterator();
        var n: usize = 0;

        for (directory_entries) |*directory_entry| {
            var file_name_slice: []u8 = &file_name_buf;
            const fat_directory_entry: *fat.Directory.Entry.Normal = it.next(&file_name_slice) orelse break;

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
            n += 1;
        }

        return n;
    }

    pub fn changeWorkingDirectory(self: *Directory, request: Request.ChangeWorkingDirectory) !void {
        if (request.path_offset + request.path_length > service.file_system.buffer_capacity)
            return error.InvalidParameter;
        const path = self.channel.buffer[request.path_offset..][0..request.path_length];

        if (path.len == 0) {
            self.working_directory = self.root_directory;
            return;
        }

        const lookup_result = try self.lookup(path);
        if (lookup_result != .directory)
            return error.InvalidParameter;

        self.working_directory = lookup_result.directory;
    }

    pub fn open(self: Directory, request: Request.Open) !void {
        errdefer syscall.regionFree(.self, request.handle) catch {};

        if (request.path_offset + request.path_length > service.file_system.buffer_capacity)
            return error.InvalidParameter;
        if (request.path_length == 0)
            return error.InvalidParameter;
        const path = self.channel.buffer[request.path_offset..][0..request.path_length];
        const lookup_result = try self.lookup(path);

        const channel_size_in_bytes: usize = if (lookup_result == .directory)
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
        new_client.* = if (lookup_result == .directory)
            .{ .directory = .{
                .channel = @ptrCast(channel_ptr),
                .root_directory = lookup_result.directory,
                .working_directory = lookup_result.directory,
            } }
        else
            .{ .file = .{
                .channel = @ptrCast(channel_ptr),
                .file = lookup_result.file,
            } };
    }

    const LookupResult = union(enum) {
        directory: fat.Directory,
        file: fat.File,
    };
    fn lookup(self: Directory, path: []const u8) !LookupResult {
        const path_is_absolute = path[0] == '/';
        var result: LookupResult = .{ .directory = if (path_is_absolute) self.root_directory else self.working_directory };

        var path_it = mem.tokenizeScalar(u8, path, '/');
        var file_name_buf: [service.file_system.DirectoryEntry.name_capacity]u8 = undefined;
        var file_name_slice: []u8 = &file_name_buf;

        while (path_it.next()) |path_part| {
            if (result == .file)
                return error.NotFound;
            if (mem.eql(u8, path_part, "..") and result.directory.eql(self.root_directory))
                continue;

            var dir_it = result.directory.iterator();
            while (dir_it.next(&file_name_slice)) |directory_entry| : (file_name_slice = &file_name_buf) {
                if (!mem.eql(u8, file_name_slice, path_part))
                    continue;

                if (directory_entry.cluster_number_low == 0) {
                    result = .{ .directory = self.root_directory };
                    break;
                }

                const sector_index = fat.sectorFromCluster(directory_entry.cluster_number_low);
                const is_dir = directory_entry.attributes.directory;
                result = if (is_dir)
                    .{ .directory = .{ .sector_index = sector_index } }
                else
                    .{ .file = .{ .sector_index = sector_index } };

                break;
            } else return error.NotFound;
        }

        return result;
    }
};

pub const File = struct {
    channel: *service.file.provide.Type,
    file: fat.File,

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

    pub fn handleRequest(self: File, request: Request) void {
        _ = self;
        _ = request;
    }
};
