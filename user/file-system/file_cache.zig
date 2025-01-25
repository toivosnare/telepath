const std = @import("std");
const mem = std.mem;
const unicode = std.unicode;
const Wyhash = std.hash.Wyhash;
const libt = @import("libt");
const syscall = libt.syscall;
const Handle = libt.Handle;
const service = libt.service;
const Spinlock = libt.sync.Spinlock;
const scache = @import("sector_cache.zig");
const fat = @import("fat.zig");
const Sector = fat.Sector;

pub const Entry = struct {
    lock: Spinlock = .{},
    short_name: [short_name_length]u8 = undefined,
    long_name: []u8 = &.{},
    parent_start_sector: Sector = fat.invalid_sector,
    start_sector: Sector = fat.invalid_sector,
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

    fn getChildSlow(self: *Entry, child_name: []const u8, name_hash_bucket: *Bucket) !*Entry {
        var dir_it = DirectoryIterator.init(self, 0);
        defer dir_it.deinit();

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
        return &sector_hash_buckets[start_sector & sector_hash_mask];
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

    pub fn isRootDirectory(self: Entry) bool {
        return self.start_sector == self.parent_start_sector;
    }

    pub fn logicalSectorToPhysical(self: Entry, logical_sector: usize) Sector {
        if (self.isRootDirectory())
            return self.start_sector + logical_sector;

        var logical_cluster = logical_sector / fat.sectors_per_cluster;
        const cluster = fat.clusterFromSector(self.start_sector);

        while (logical_cluster > 0) {
            // TODO: follow FAT chains.
            logical_cluster -= 1;
        }

        return fat.sectorFromCluster(cluster) + (logical_sector % fat.sectors_per_cluster);
    }

    pub fn read(self: Entry, start_seek_offset: usize, region_handle: Handle, region_offset: usize, n: usize) usize {
        // TODO: check overflow.
        if (start_seek_offset >= self.size)
            return 0;
        const bytes_to_write = @min(n, self.size - start_seek_offset);
        var bytes_written: usize = 0;
        var seek_offset = start_seek_offset;

        while (bytes_written < bytes_to_write) {
            const sector = self.logicalSectorToPhysical(seek_offset / fat.sector_size);
            const sentry = scache.get(sector);
            defer scache.put(sentry);

            const size = @min(n - bytes_written, fat.sector_size - seek_offset % fat.sector_size);
            const from = @intFromPtr(&sentry.data) + (seek_offset % fat.sector_size);
            syscall.regionWrite(.self, region_handle, @ptrFromInt(from), region_offset + bytes_written, size) catch break;

            bytes_written += size;
            seek_offset += size;
        }

        return bytes_written;
    }

    pub fn write(self: Entry, start_seek_offset: usize, region_handle: Handle, region_offset: usize, n: usize) usize {
        var bytes_read: usize = 0;
        var seek_offset = start_seek_offset;

        while (bytes_read < n) {
            const sector = self.logicalSectorToPhysical(seek_offset / fat.sector_size);
            const sentry = scache.get(sector);
            defer scache.put(sentry);

            const size = @min(n - bytes_read, fat.sector_size - seek_offset % fat.sector_size);
            const to = @intFromPtr(&sentry.data) + (seek_offset % fat.sector_size);
            syscall.regionRead(.self, region_handle, @ptrFromInt(to), region_offset + bytes_read, size) catch break;
            sentry.state = .dirty;

            bytes_read += size;
            seek_offset += size;
        }

        return bytes_read;
    }

    pub fn readdir(self: *Entry, seek_offset: *usize, region_handle: Handle, region_offset: usize, n: usize) usize {
        const region_size = syscall.regionSize(.self, region_handle) catch return 0;
        if (region_size * mem.page_size < (region_offset + n) * @sizeOf(service.file_system.DirectoryEntry))
            return 0;

        const region_ptr = syscall.regionMap(.self, region_handle, null) catch return 0;
        defer _ = syscall.regionUnmap(.self, region_ptr) catch {};

        const directory_entries_start: [*]service.file_system.DirectoryEntry = @ptrCast(region_ptr);
        const directory_entries = directory_entries_start[region_offset .. region_offset + n];

        var it = DirectoryIterator.init(self, seek_offset.*);
        defer it.deinit();

        var file_name_buf: [service.file_system.DirectoryEntry.name_capacity]u8 = undefined;
        var entries_read: usize = 0;

        for (directory_entries) |*directory_entry| {
            var file_name_slice: []u8 = &file_name_buf;
            const fat_directory_entry: *fat.DirectoryEntry.Normal = it.next(&file_name_slice) orelse break;

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
            entries_read += 1;
        }

        seek_offset.* = it.seek_offset;
        return entries_read;
    }

    pub const DirectoryIterator = struct {
        entry: *Entry,
        seek_offset: usize,
        sentry: *scache.Entry,
        logical_sector_index: usize,

        pub fn init(entry: *Entry, seek_offset: usize) DirectoryIterator {
            const aligned_seek_offset = mem.alignForward(usize, seek_offset, @sizeOf(fat.DirectoryEntry));
            const logical_sector_index = aligned_seek_offset / fat.sector_size;
            const physical_sector = entry.logicalSectorToPhysical(logical_sector_index);
            const sentry = scache.get(physical_sector);
            return .{
                .entry = entry,
                .seek_offset = aligned_seek_offset,
                .sentry = sentry,
                .logical_sector_index = logical_sector_index,
            };
        }

        pub fn next(self: *DirectoryIterator, file_name: *[]u8) ?*fat.DirectoryEntry.Normal {
            var lfn_buffer: [256]u16 = undefined;
            var lfn_length: usize = 0;

            while (true) {
                defer self.advance();
                const directory_entry: *fat.DirectoryEntry = @alignCast(@ptrCast(&self.sentry.data[self.seek_offset % fat.sector_size]));

                if (directory_entry.normal.name[0] == 0)
                    return null;

                if (directory_entry.isLongFileNameEntry()) {
                    const lfn_entry = &directory_entry.long_file_name;

                    // Skip if we somehow got seeked in the middle of a LFN entry.
                    // TODO: Maybe also skip the following 8.3 entry.
                    if (!lfn_entry.sequence.last and lfn_length == 0)
                        continue;

                    var offset: usize = (lfn_entry.sequence.number - 1) * fat.DirectoryEntry.LongFileName.file_name_total_capacity;
                    defer if (lfn_entry.sequence.last) {
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
                    continue;
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

        pub fn deinit(self: DirectoryIterator) void {
            scache.put(self.sentry);
        }

        fn advance(self: *DirectoryIterator) void {
            self.seek_offset += @sizeOf(fat.DirectoryEntry);
            const logical_sector_index = self.seek_offset / fat.sector_size;
            if (logical_sector_index == self.logical_sector_index)
                return;

            scache.put(self.sentry);
            self.logical_sector_index = logical_sector_index;
            const physical_sector = self.entry.logicalSectorToPhysical(self.logical_sector_index);
            self.sentry = scache.get(physical_sector);
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
