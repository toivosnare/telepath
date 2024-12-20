const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const unicode = std.unicode;
const cache = @import("cache.zig");

pub var sectors_per_cluster: u8 = undefined;
pub var fat_sector: usize = undefined;

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
                    (file_name.*)[name_length] = '.';

                    const extension_length = mem.indexOfScalar(u8, &normal.extension, ' ') orelse Normal.extension_capacity;
                    @memcpy(file_name.ptr + name_length + 1, normal.extension[0..extension_length]);

                    file_name.len = name_length + 1 + extension_length;
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
                self.cache_entry = cache.getSector(old_entry.sector + 1);
                cache.returnSector(old_entry);
                return;
            }

            self.sector_index = 0;
            @panic("unimplemented");
        }
    };
};
