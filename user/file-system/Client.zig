const std = @import("std");
const mem = std.mem;
const libt = @import("libt");
const file_system = libt.service.file_system;
const fat = @import("fat.zig");
const Directory = fat.Directory;
const File = fat.File;
const Client = @This();

channel: *file_system.provide.Type,
root_directory: Directory = undefined,
working_directory: Directory = undefined,

pub fn read(self: *Client, directory_entries: []file_system.DirectoryEntry) usize {
    var file_name_buf: [file_system.DirectoryEntry.name_capacity]u8 = undefined;
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

pub fn changeWorkingDirectory(self: *Client, path: []const u8) !void {
    if (path.len == 0) {
        self.working_directory = self.root_directory;
        return;
    }

    const lookup_result = try self.lookup(path);
    if (lookup_result != .directory)
        return error.NotADirectory;
    self.working_directory = lookup_result.directory;
}

pub fn open(self: *Client, path: []const u8) !LookupResult {
    return self.lookup(path);
}

pub const LookupResult = union(enum) {
    directory: Directory,
    file: File,
};
fn lookup(self: Client, path: []const u8) !LookupResult {
    const path_is_absolute = path[0] == '/';
    var result: LookupResult = .{ .directory = if (path_is_absolute) self.root_directory else self.working_directory };

    var path_it = mem.tokenizeScalar(u8, path, '/');
    var file_name_buf: [file_system.DirectoryEntry.name_capacity]u8 = undefined;
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
