const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const unicode = std.unicode;
const cache = @import("cache.zig");

const VolumeBootRecord = extern struct {
    jump: [3]u8,
    oem_identifier: [8]u8,
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8,
    reserved_sectors: u16 align(1),
    file_allocation_tables: u8,
    root_directory_entries: u16 align(1),
    total_sectors: u16 align(1),
    media_descriptor_type: u8,
    sectors_per_fat: u16 align(1),
    sectors_per_track: u16 align(1),
    heads: u16 align(1),
    hidden_sectors: u32 align(1),
    large_sector_count: u32 align(1),
};

var sectors_per_cluster: u8 = undefined;
var fat_sector: usize = undefined;
var first_data_sector: usize = undefined;

pub fn init(vbr_sector: usize) usize {
    const vbr_entry = cache.getSector(vbr_sector);
    defer cache.returnSector(vbr_entry);
    const vbr: *const VolumeBootRecord = @ptrCast(&vbr_entry.data);

    sectors_per_cluster = vbr.sectors_per_cluster;
    fat_sector = vbr_sector + vbr.reserved_sectors;
    const root_directory_sector = fat_sector + vbr.file_allocation_tables * vbr.sectors_per_fat;
    const root_directory_sectors = math.divCeil(usize, vbr.root_directory_entries * @sizeOf(DirectoryEntry), 512) catch unreachable;
    first_data_sector = root_directory_sector + root_directory_sectors;

    return root_directory_sector;
}

pub fn sectorFromCluster(cluster: usize) usize {
    return first_data_sector + (cluster - 2) * sectors_per_cluster;
}

pub const DirectoryEntry = extern union {
    normal: Normal,
    long_file_name: LongFileName,

    pub const Normal = extern struct {
        name: [name_capacity]u8,
        extension: [extension_capacity]u8,
        attributes: Attributes,
        _: u8,
        creation_time_cs: u8,
        creation_time: Time,
        creation_date: Date,
        access_date: Date,
        cluster_number_high: u16,
        modification_time: Time,
        modification_date: Date,
        cluster_number_low: u16,
        size: u32,

        pub const name_capacity = 8;
        pub const extension_capacity = 3;
    };

    pub const LongFileName = extern struct {
        sequence: packed struct(u8) {
            number: u5,
            zero: u1,
            last: bool,
            _: u1,
        },
        name_1: [name_1_capacity]u16 align(1),
        attributes: Attributes,
        long_entry_type: enum(u8) {
            _,
        },
        checksum: u8,
        name_2: [name_2_capacity]u16,
        cluster: u16,
        name_3: [name_3_capacity]u16,

        pub const name_1_capacity = 5;
        pub const name_2_capacity = 6;
        pub const name_3_capacity = 2;
        pub const file_name_total_capacity = name_1_capacity + name_2_capacity + name_3_capacity;
    };

    pub const Attributes = packed struct(u8) {
        read_only: bool = false,
        hidden: bool = false,
        system: bool = false,
        volume_id: bool = false,
        directory: bool = false,
        archive: bool = false,
        _: u2 = 0,

        pub const long_file_name: Attributes = .{
            .read_only = true,
            .hidden = true,
            .system = true,
            .volume_id = true,
        };
    };

    pub const Time = packed struct(u16) {
        second: u5,
        minute: u6,
        hour: u5,
    };

    pub const Date = packed struct(u16) {
        day: u5,
        month: u4,
        year: u7,
    };

    comptime {
        assert(@sizeOf(DirectoryEntry) == 32);
    }

    pub const Iterator = struct {
        cache_entry: *cache.Entry,
        byte_index: u16 = 0,
        sector_index: u8 = 0,

        pub fn init(start_sector: usize) Iterator {
            return .{ .cache_entry = cache.getSector(start_sector) };
        }

        pub fn next(self: *Iterator, file_name: *[]u8) ?*DirectoryEntry.Normal {
            var lfn_buffer: [256]u16 = undefined;
            var lfn_length: usize = 0;

            while (true) {
                defer self.fetch();
                const directory_entry: *DirectoryEntry = @alignCast(@ptrCast(&self.cache_entry.data[self.byte_index]));

                if (directory_entry.normal.name[0] == 0)
                    return null;

                if (@as(u8, @bitCast(directory_entry.normal.attributes)) == @as(u8, @bitCast(Attributes.long_file_name))) {
                    const lfn_entry = &directory_entry.long_file_name;
                    var offset: usize = (lfn_entry.sequence.number - 1) * LongFileName.file_name_total_capacity;

                    defer if (lfn_length == 0) {
                        lfn_length = offset;
                    };

                    // The first part of the file name is not aligned so we cannot use mem.indexOfScalar.
                    const file_name_1_len = for (0.., &lfn_entry.name_1) |i, c| {
                        if (c == 0x0000)
                            break i;
                    } else LongFileName.name_1_capacity;
                    // const file_name_1_len = mem.indexOfScalar(u16, &lfn_entry.file_name_1, 0x0000) orelse DirectoryEntry.LongFileName.file_name_1_capacity;
                    @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_1[0..file_name_1_len]);
                    offset += file_name_1_len;
                    if (file_name_1_len < LongFileName.name_1_capacity)
                        continue;

                    const file_name_2_len = mem.indexOfScalar(u16, &lfn_entry.name_2, 0x0000) orelse LongFileName.name_2_capacity;
                    @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_2[0..file_name_2_len]);
                    offset += file_name_2_len;
                    if (file_name_2_len < LongFileName.name_2_capacity)
                        continue;

                    const file_name_3_len = mem.indexOfScalar(u16, &lfn_entry.name_3, 0x0000) orelse LongFileName.name_3_capacity;
                    @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_3[0..file_name_3_len]);
                    offset += file_name_3_len;
                }

                if (directory_entry.normal.attributes.volume_id)
                    continue;

                const normal = &directory_entry.normal;

                if (lfn_length > 0) {
                    // Convert UTF-16 to UTF-8.
                    const utf8_length = unicode.utf16LeToUtf8(file_name.*, lfn_buffer[0..lfn_length]) catch 0;
                    file_name.len = utf8_length;
                } else {
                    // Remove padding from 8.3 file name + extension.
                    const name_length = std.mem.indexOfScalar(u8, &normal.name, ' ') orelse Normal.name_capacity;
                    @memcpy(file_name.ptr, normal.name[0..name_length]);

                    const extension_length = mem.indexOfScalar(u8, &normal.extension, ' ') orelse Normal.extension_capacity;
                    if (extension_length > 0) {
                        file_name.len += name_length + extension_length;
                        (file_name.*)[name_length] = '.';
                        @memcpy(file_name.ptr + name_length + 1, normal.extension[0..extension_length]);
                    } else {
                        file_name.len = name_length;
                    }
                }
                return normal;
            }
        }

        fn fetch(self: *Iterator) void {
            self.byte_index += @sizeOf(DirectoryEntry);
            if (self.byte_index < 512)
                return;

            self.byte_index = 0;
            self.sector_index += 1;

            if (self.sector_index < sectors_per_cluster) {
                const old_entry = self.cache_entry;
                self.cache_entry = cache.getSector(old_entry.sector_index + 1);
                cache.returnSector(old_entry);
                return;
            }

            self.sector_index = 0;
            @panic("unimplemented");
        }
    };
};
