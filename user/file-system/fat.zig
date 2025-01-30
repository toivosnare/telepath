const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const unicode = std.unicode;

pub const Sector = usize;
pub const sector_size = 512;
pub const invalid_sector = math.maxInt(Sector);
pub const Cluster = usize;

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

pub const DirectoryEntry = extern union {
    normal: Normal,
    long_file_name: LongFileName,

    pub fn isLongFileNameEntry(self: DirectoryEntry) bool {
        return @as(u8, @bitCast(self.normal.attributes)) == @as(u8, @bitCast(Attributes.long_file_name));
    }

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
};

pub var sectors_per_cluster: u8 = undefined;
var fat_sector: Sector = undefined;
pub var root_directory_sector: Sector = undefined;
pub var root_directory_size: usize = undefined;
var first_data_sector: Sector = undefined;

pub fn init(vbr_sector: Sector, vbr: *const VolumeBootRecord) Sector {
    sectors_per_cluster = vbr.sectors_per_cluster;
    fat_sector = vbr_sector + vbr.reserved_sectors;
    root_directory_sector = fat_sector + vbr.file_allocation_tables * vbr.sectors_per_fat;
    root_directory_size = math.divCeil(usize, vbr.root_directory_entries * @sizeOf(DirectoryEntry), sector_size) catch unreachable;
    first_data_sector = root_directory_sector + root_directory_size;

    return root_directory_sector;
}

pub fn sectorFromCluster(cluster: Cluster) ?Sector {
    if (cluster < 2)
        return null;
    return first_data_sector + (cluster - 2) * sectors_per_cluster;
}

pub fn clusterFromSector(sector: Sector) ?Cluster {
    if (sector < first_data_sector)
        return null;
    return ((sector - first_data_sector) / sectors_per_cluster) + 2;
}
