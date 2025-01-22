const std = @import("std");
const mem = std.mem;
const unicode = std.unicode;
const Wyhash = std.hash.Wyhash;
const libt = @import("libt");
const service = libt.service;
const Spinlock = libt.sync.Spinlock;
const scache = @import("sector_cache.zig");
const Sector = scache.Sector;
const fat = @import("fat.zig");

pub const Entry = struct {
    lock: Spinlock = .{},
    short_name: [short_name_length]u8 = undefined,
    long_name: []u8 = &.{},
    parent_start_sector: Sector = .invalid,
    start_sector: Sector = 0,
    size: usize = 0,
    ref_count: usize = 0,
    kind: enum { regular, directory } = .regular,
    name_hash_next: ?*Entry = null,
    sector_hash_next: ?*Entry = null,
    lru_list_next: ?*Entry = null,
    lru_list_prev: ?*Entry = null,

    const short_name_length = 16;

    pub fn ref(self: *Entry) void {
        self.ref_count += 1;
    }

    pub fn unref(self: *Entry) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.addToLruList();
        }
    }

    pub fn lookup(self: *Entry, path: []const u8) !*Entry {
        var entry: *Entry = self;
        entry.ref();

        var path_it = mem.tokenizeScalar(u8, path, '/');
        while (path_it.next()) |path_part| {
            if (mem.eql(u8, path_part, "."))
                continue;

            const old_entry = entry;
            defer old_entry.unref();

            if (entry.kind != .directory)
                return error.InvalidType;
            if (mem.eql(u8, path_part, ".."))
                return error.InvalidParameter;

            const name_hash_bucket = nameHashBucket(self.start_sector, path_part);
            if (entry.getChildFast(path_part, name_hash_bucket)) |e| {
                entry = e;
                continue;
            }
            entry = try entry.getChildSlow(path_part, name_hash_bucket);
        }

        return entry;
    }

    fn nameHashBucket(parent_start_sector: Sector, child_name: []const u8) *Bucket {
        var hash_state = Wyhash.init(0);
        hash_state.update(mem.asBytes(&parent_start_sector));
        hash_state.update(child_name);
        const hash = hash_state.final();
        return &name_hash_buckets[hash % name_hash_bucket_count];
    }

    fn getChildFast(self: Entry, child_name: []const u8, name_hash_bucket: *Bucket) ?*Entry {
        var entry = name_hash_bucket.*;
        while (entry) |e| : (entry = e.name_hash_next) {
            if (e.parent_start_sector != self.start_sector)
                continue;
            if (!mem.eql(u8, e.getName(), child_name))
                continue;
            e.removeFromLruList();
            e.ref();
            return entry;
        }
        return null;
    }

    fn getChildSlow(self: Entry, child_name: []const u8, name_hash_bucket: *Bucket) !*Entry {
        var dir_it = try self.directoryIterator();
        var file_name_buf: [service.file_system.DirectoryEntry.name_capacity]u8 = undefined;
        var file_name_slice: []u8 = &file_name_buf;

        while (dir_it.next(&file_name_slice)) |directory_entry| : (file_name_slice = &file_name_buf) {
            if (!mem.eql(u8, file_name_slice, child_name))
                continue;

            const child_start_sector = fat.sectorFromCluster(directory_entry.cluster_number_low);
            const sector_hash_bucket = sectorHashBucket(child_start_sector);
            if (getBySector(child_start_sector, sector_hash_bucket)) |child| {
                return child;
            }

            const child = Entry.popLruList();
            child.removeFromSectorHashChain();
            child.removeFromNameHashChain();

            child.setName(child_name);
            child.parent_start_sector = self.start_sector;
            child.start_sector = child_start_sector;
            child.size = directory_entry.size;
            child.ref_count = 1;
            child.kind = if (directory_entry.attributes.directory) .directory else .regular;

            // Prepend to name hash chain.
            child.name_hash_next = name_hash_bucket.*;
            name_hash_bucket.* = child;

            // Prepend to sector hash chain.
            child.sector_hash_next = sector_hash_bucket.*;
            sector_hash_bucket.* = child;

            return child;
        } else return error.NotFound;
    }

    fn sectorHashBucket(start_sector: Sector) *Bucket {
        return &sector_hash_buckets[@intFromEnum(start_sector) & sector_hash_mask];
    }

    fn getBySector(start_sector: Sector, sector_hash_bucket: *Bucket) ?*Entry {
        var entry = sector_hash_bucket.*;
        while (entry) |e| : (entry = e.sector_hash_next) {
            if (e.start_sector == start_sector) {
                e.removeFromLruList();
                e.ref();
                return e;
            }
        }
        return null;
    }

    fn getName(self: *Entry) []const u8 {
        const short_len = mem.indexOfScalar(u8, &self.short_name, 0) orelse self.short_name.len;
        if (short_len == 0) {
            return self.long_name;
        } else {
            return self.short_name[0..short_len];
        }
    }

    fn setName(self: *Entry, name: []const u8) void {
        if (name.len > self.short_name.len) {
            @panic("not implemented");
        } else {
            @memcpy(self.short_name[0..name.len], name);
            if (name.len < self.short_name.len)
                self.short_name[name.len] = 0;
        }
    }

    pub fn directoryIterator(self: Entry) !DirectoryIterator {
        if (self.kind != .directory)
            return error.InvalidType;
        return .{ .cache_entry = scache.get(self.start_sector) };
    }

    pub fn popLruList() *Entry {
        const result = lru_list_head orelse @panic("all cache elements in use");
        lru_list_head = result.lru_list_next;
        if (lru_list_head) |head|
            head.lru_list_prev = null;
        if (result == lru_list_tail)
            lru_list_tail = null;

        result.lru_list_next = null;
        result.lru_list_prev = null;
        return result;
    }

    fn removeFromLruList(self: *Entry) void {
        if (self.lru_list_prev) |prev|
            prev.lru_list_next = self.lru_list_next
        else if (lru_list_head == self)
            lru_list_head = self.lru_list_next;

        if (self.lru_list_next) |next|
            next.lru_list_prev = self.lru_list_prev
        else if (lru_list_tail == self)
            lru_list_tail = self.lru_list_prev;
    }

    fn addToLruList(self: *Entry) void {
        if (lru_list_tail) |tail| {
            tail.lru_list_next = self;
        } else {
            lru_list_head = self;
        }
        self.lru_list_prev = lru_list_tail;
        self.lru_list_next = null;
        lru_list_tail = self;
    }

    pub fn removeFromSectorHashChain(self: *Entry) void {
        const bucket = sectorHashBucket(self.start_sector);
        var prev_entry: ?*Entry = null;
        var entry = bucket.*;
        while (entry) |e| {
            if (e == self) {
                if (prev_entry) |prev|
                    prev.sector_hash_next = self.sector_hash_next
                else
                    bucket.* = self.sector_hash_next;
                self.sector_hash_next = null;
                return;
            }
            prev_entry = entry;
            entry = e.sector_hash_next;
        }
    }

    pub fn removeFromNameHashChain(self: *Entry) void {
        const bucket = nameHashBucket(self.parent_start_sector, self.getName());
        var prev_entry: ?*Entry = null;
        var entry = bucket.*;
        while (entry) |e| {
            if (e == self) {
                if (prev_entry) |prev|
                    prev.name_hash_next = self.name_hash_next
                else
                    bucket.* = self.name_hash_next;
                self.name_hash_next = null;
                return;
            }
            prev_entry = entry;
            entry = e.name_hash_next;
        }
    }

    pub fn logicalSectorToPhysical(self: Entry, logical_sector: usize) Sector {
        var logical_cluster = logical_sector / fat.sectors_per_cluster;
        const cluster = fat.clusterFromSector(self.start_sector);

        while (logical_cluster > 0) {
            // TODO: follow FAT chains.
            logical_cluster -= 1;
        }

        return @enumFromInt(@intFromEnum(fat.sectorFromCluster(cluster)) + (logical_sector % fat.sectors_per_cluster));
    }

    pub const DirectoryIterator = struct {
        cache_entry: *scache.Entry,
        byte_index: u16 = 0,
        sector_index: u8 = 0,

        pub fn next(self: *DirectoryIterator, file_name: *[]u8) ?*fat.DirectoryEntry.Normal {
            var lfn_buffer: [256]u16 = undefined;
            var lfn_length: usize = 0;

            while (true) {
                defer self.fetch();
                const directory_entry: *fat.DirectoryEntry = @alignCast(@ptrCast(&self.cache_entry.data[self.byte_index]));

                if (directory_entry.normal.name[0] == 0)
                    return null;

                if (@as(u8, @bitCast(directory_entry.normal.attributes)) == @as(u8, @bitCast(fat.DirectoryEntry.Attributes.long_file_name))) {
                    const lfn_entry = &directory_entry.long_file_name;
                    var offset: usize = (lfn_entry.sequence.number - 1) * fat.DirectoryEntry.LongFileName.file_name_total_capacity;

                    defer if (lfn_length == 0) {
                        lfn_length = offset;
                    };

                    // The first part of the file name is not aligned so we cannot use mem.indexOfScalar.
                    const file_name_1_len = for (0.., &lfn_entry.name_1) |i, c| {
                        if (c == 0x0000)
                            break i;
                    } else fat.DirectoryEntry.LongFileName.name_1_capacity;
                    // const file_name_1_len = mem.indexOfScalar(u16, &lfn_entry.file_name_1, 0x0000) orelse DirectoryEntry.LongFileName.file_name_1_capacity;
                    @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_1[0..file_name_1_len]);
                    offset += file_name_1_len;
                    if (file_name_1_len < fat.DirectoryEntry.LongFileName.name_1_capacity)
                        continue;

                    const file_name_2_len = mem.indexOfScalar(u16, &lfn_entry.name_2, 0x0000) orelse fat.DirectoryEntry.LongFileName.name_2_capacity;
                    @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_2[0..file_name_2_len]);
                    offset += file_name_2_len;
                    if (file_name_2_len < fat.DirectoryEntry.LongFileName.name_2_capacity)
                        continue;

                    const file_name_3_len = mem.indexOfScalar(u16, &lfn_entry.name_3, 0x0000) orelse fat.DirectoryEntry.LongFileName.name_3_capacity;
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
                    const name_length = std.mem.indexOfScalar(u8, &normal.name, ' ') orelse fat.DirectoryEntry.Normal.name_capacity;
                    @memcpy(file_name.ptr, normal.name[0..name_length]);

                    const extension_length = mem.indexOfScalar(u8, &normal.extension, ' ') orelse fat.DirectoryEntry.Normal.extension_capacity;
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

        fn fetch(self: *DirectoryIterator) void {
            self.byte_index += @sizeOf(fat.DirectoryEntry);
            if (self.byte_index < 512)
                return;

            self.byte_index = 0;
            self.sector_index += 1;

            if (self.sector_index < fat.sectors_per_cluster) {
                const old_entry = self.cache_entry;
                const next_sector: Sector = @enumFromInt(@intFromEnum(old_entry.sector) + 1);
                self.cache_entry = scache.get(next_sector);
                scache.put(old_entry);
                return;
            }

            self.sector_index = 0;
            @panic("unimplemented");
        }
    };
};

const Bucket = ?*Entry;

const sector_hash_n = 8;
const sector_hash_bucket_count = 1 << sector_hash_n;
const sector_hash_mask = sector_hash_bucket_count - 1;
const name_hash_bucket_count = 128;
const entry_count = 128;

var name_hash_buckets: [name_hash_bucket_count]Bucket = .{null} ** name_hash_bucket_count;
var sector_hash_buckets: [sector_hash_bucket_count]Bucket = .{null} ** sector_hash_bucket_count;
var lru_list_head: ?*Entry = null;
var lru_list_tail: ?*Entry = null;
var entries: [entry_count]Entry = undefined;

pub fn init(root_start_sector: Sector) *Entry {
    var prev: ?*Entry = null;
    for (&entries) |*entry| {
        if (prev) |p| {
            p.lru_list_next = entry;
        } else {
            lru_list_head = entry;
        }
        entry.lru_list_prev = prev;
        prev = entry;
    }
    prev.?.lru_list_next = null;
    lru_list_tail = prev;

    const root_entry = Entry.popLruList();
    root_entry.start_sector = root_start_sector;
    root_entry.parent_start_sector = root_start_sector;
    root_entry.ref_count = 1;
    root_entry.kind = .directory;
    return root_entry;
}
