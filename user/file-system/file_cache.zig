const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const unicode = std.unicode;
const Wyhash = std.hash.Wyhash;
const libt = @import("libt");
const syscall = libt.syscall;
const Handle = libt.Handle;
const service = libt.service;
const DateTime = service.rtc_driver.DateTime;
const Spinlock = libt.sync.Spinlock;
const services = @import("services");
const rtc = services.rtc;
const scache = @import("sector_cache.zig");
const fat = @import("fat.zig");
const Sector = fat.Sector;

pub const Entry = struct {
    start_sector: ?Sector,
    parent_start_sector: ?Sector,
    parent_offset: usize,
    short_name: [short_name_capacity]u8,
    long_name: []u8,
    kind: enum { regular, directory },
    ref_count: usize,
    size: usize,
    creation_time: DateTime,
    access_time: DateTime,
    modification_time: DateTime,
    name_hash_next: ?*Entry,
    sector_hash_next: ?*Entry,
    lru_list_next: ?*Entry,
    lru_list_prev: ?*Entry,
    // lock: Spinlock,

    const short_name_capacity = 16;

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

            entry = entry.getChild(path_part) orelse return error.NotFound;
        }

        return entry;
    }

    fn getChild(self: *Entry, child_name: []const u8) ?*Entry {
        const name_hash_bucket = nameHashBucket(self.start_sector.?, child_name);
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

        var seek_offset: usize = 0;
        while (self.getNextChild(&seek_offset)) |fentry| {
            if (mem.eql(u8, fentry.getName(), child_name))
                return fentry;
            fentry.unref();
        }

        return null;
    }

    fn getNextChild(self: Entry, seek_offset: *usize) ?*Entry {
        seek_offset.* = mem.alignForward(usize, seek_offset.*, @sizeOf(fat.DirectoryEntry));
        var logical_sector = seek_offset.* / fat.sector_size;
        var sentry = scache.get(self.physicalFromLogical(logical_sector));
        defer scache.put(sentry);

        var lfn_buffer: [256]u16 = undefined;
        var lfn_length: usize = 0;

        while (true) {
            const directory_entry: *fat.DirectoryEntry = @alignCast(@ptrCast(&sentry.data[seek_offset.* % fat.sector_size]));
            if (directory_entry.normal.name[0] == 0)
                return null;

            defer {
                seek_offset.* += @sizeOf(fat.DirectoryEntry);
                const next_logical_sector = seek_offset.* / fat.sector_size;
                if (next_logical_sector != logical_sector) {
                    logical_sector = next_logical_sector;
                    const old_sentry = sentry;
                    sentry = scache.get(self.physicalFromLogical(logical_sector));
                    scache.put(old_sentry);
                }
            }

            if (directory_entry.isLongFileNameEntry()) {
                handleLfnEntry(&directory_entry.long_file_name, &lfn_buffer, &lfn_length);
                continue;
            }
            if (directory_entry.normal.attributes.volume_id)
                continue;
            if (mem.eql(u8, &directory_entry.normal.name, ".       "))
                continue;
            if (mem.eql(u8, &directory_entry.normal.name, "..      "))
                continue;

            const normal = &directory_entry.normal;

            const child_start_sector = fat.sectorFromCluster(normal.cluster_number_low);
            if (child_start_sector) |start_sector| {
                if (getBySector(start_sector)) |child| {
                    if (child.parent_start_sector) |parent_start_sector| {
                        assert(parent_start_sector == self.start_sector);
                        assert(child.parent_offset == seek_offset.*);
                    } else {
                        child.parent_start_sector = self.start_sector;
                        child.parent_offset = seek_offset.*;
                        child.setName(lfn_buffer[0..lfn_length], normal);
                        child.ref();
                        child.size = normal.size;
                    }
                    return child;
                }
            }

            const child = Entry.popLruList();
            child.start_sector = child_start_sector;
            child.parent_start_sector = self.start_sector.?;
            child.parent_offset = seek_offset.*;
            child.setName(lfn_buffer[0..lfn_length], normal);
            child.kind = if (normal.attributes.directory) .directory else .regular;
            child.ref_count = 1;
            child.size = normal.size;

            child.creation_time = .{
                .year = @as(u16, 1980) + normal.creation_date.year,
                .month = normal.creation_date.month,
                .day = normal.creation_date.day,
                .hours = normal.creation_time.hour,
                .minutes = normal.creation_time.minute,
                .seconds = @as(u8, 2) * normal.creation_time.second,
            };
            if (normal.creation_time_cs >= 100)
                child.creation_time.seconds += 1;
            child.access_time = .{
                .year = @as(u16, 1980) + normal.access_date.year,
                .month = normal.access_date.month,
                .day = normal.access_date.day,
                .hours = 0,
                .minutes = 0,
                .seconds = 0,
            };
            child.modification_time = .{
                .year = @as(u16, 1980) + normal.modification_date.year,
                .month = normal.modification_date.month,
                .day = normal.modification_date.day,
                .hours = normal.modification_time.hour,
                .minutes = normal.modification_time.minute,
                .seconds = @as(u8, 2) * normal.modification_time.second,
            };

            // Prepend to name hash chain.
            const name_hash_bucket = nameHashBucket(self.start_sector.?, child.getName());
            child.name_hash_next = name_hash_bucket.*;
            name_hash_bucket.* = child;

            // Prepend to sector hash chain.
            if (child_start_sector) |css| {
                const sector_hash_bucket = sectorHashBucket(css);
                child.sector_hash_next = sector_hash_bucket.*;
                sector_hash_bucket.* = child;
            }

            return child;
        }
    }

    fn handleLfnEntry(lfn_entry: *fat.DirectoryEntry.LongFileName, lfn_buffer: []u16, lfn_length: *usize) void {
        // Skip if we somehow got seeked in the middle of a LFN entry.
        // TODO: Maybe also skip the following 8.3 entry.
        if (!lfn_entry.sequence.last and lfn_length.* == 0)
            return;

        var offset: usize = (lfn_entry.sequence.number - 1) * fat.DirectoryEntry.LongFileName.file_name_total_capacity;
        defer if (lfn_entry.sequence.last) {
            lfn_length.* = offset;
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
            return;

        const file_name_2_len = mem.indexOfScalar(u16, &lfn_entry.name_2, 0x0000) orelse fat.DirectoryEntry.LongFileName.name_2_capacity;
        @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_2[0..file_name_2_len]);
        offset += file_name_2_len;
        if (file_name_2_len < fat.DirectoryEntry.LongFileName.name_2_capacity)
            return;

        const file_name_3_len = mem.indexOfScalar(u16, &lfn_entry.name_3, 0x0000) orelse fat.DirectoryEntry.LongFileName.name_3_capacity;
        @memcpy(lfn_buffer[offset..].ptr, lfn_entry.name_3[0..file_name_3_len]);
        offset += file_name_3_len;
    }

    fn setName(self: *Entry, lfn: []const u16, normal_entry: *fat.DirectoryEntry.Normal) void {
        var short_name_len: usize = 0;
        if (lfn.len > 0) {
            var utf8_len: usize = 0;
            var it = unicode.Utf16LeIterator.init(lfn);
            // TODO: handle invalid encodings.
            while (it.nextCodepoint() catch unreachable) |codepoint| {
                utf8_len += unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            }

            if (utf8_len > short_name_capacity) {
                self.long_name = unicode.utf16LeToUtf8Alloc(allocator, lfn) catch unreachable;
            } else {
                _ = unicode.utf16LeToUtf8(&self.short_name, lfn) catch unreachable;
                short_name_len = utf8_len;
            }
        } else {
            // Remove padding from 8.3 file name + extension.
            const name_len = std.mem.indexOfScalar(u8, &normal_entry.name, ' ') orelse fat.DirectoryEntry.Normal.name_capacity;
            @memcpy(self.short_name[0..name_len], normal_entry.name[0..name_len]);

            const extension_len = mem.indexOfScalar(u8, &normal_entry.extension, ' ') orelse fat.DirectoryEntry.Normal.extension_capacity;
            if (extension_len > 0) {
                self.short_name[name_len] = '.';
                @memcpy(self.short_name[name_len + 1 ..][0..extension_len], normal_entry.extension[0..extension_len]);
                short_name_len = name_len + 1 + extension_len;
            } else {
                short_name_len = name_len;
            }
        }
        if (short_name_len < short_name_capacity)
            self.short_name[short_name_len] = 0;
    }

    fn getName(self: *Entry) []const u8 {
        const short_len = mem.indexOfScalar(u8, &self.short_name, 0) orelse self.short_name.len;
        if (short_len == 0) {
            return self.long_name;
        } else {
            return self.short_name[0..short_len];
        }
    }

    fn getParent(self: Entry) ?*Entry {
        if (self.parent_start_sector == null)
            return null;
        const parent_start_sector = self.parent_start_sector.?;

        if (getBySector(parent_start_sector)) |parent|
            return parent;

        const parent = Entry.popLruList();
        parent.start_sector = parent_start_sector;
        parent.parent_start_sector = null;
        parent.parent_offset = 0;
        @memcpy(parent.short_name[0..1], "?");
        parent.kind = .directory;
        parent.ref_count = 1;
        parent.size = 0;

        const sector_hash_bucket = sectorHashBucket(parent_start_sector);
        parent.sector_hash_next = sector_hash_bucket.*;
        sector_hash_bucket.* = parent;

        return parent;
    }

    fn getBySector(start_sector: Sector) ?*Entry {
        const bucket = sectorHashBucket(start_sector);
        var entry = bucket.*;
        while (entry) |e| : (entry = e.sector_hash_next) {
            if (e.start_sector == start_sector) {
                e.removeFromLruList();
                e.ref();
                return e;
            }
        }
        return null;
    }

    fn physicalFromLogical(self: Entry, logical_sector: usize) Sector {
        if (self.isRootDirectory())
            return self.start_sector.? + logical_sector;

        var logical_cluster = logical_sector / fat.sectors_per_cluster;
        const cluster = fat.clusterFromSector(self.start_sector.?).?;

        while (logical_cluster > 0) {
            // TODO: follow FAT chains.
            logical_cluster -= 1;
        }

        return fat.sectorFromCluster(cluster).? + (logical_sector % fat.sectors_per_cluster);
    }

    fn isRootDirectory(self: Entry) bool {
        return self.start_sector == fat.root_directory_sector;
    }

    fn hasLongName(self: Entry) bool {
        return self.short_name[0] == 0;
    }

    pub fn read(self: *Entry, start_seek_offset: usize, region_handle: Handle, region_offset: usize, n: usize) usize {
        // TODO: check overflow.
        if (start_seek_offset >= self.size)
            return 0;
        const bytes_to_write = @min(n, self.size - start_seek_offset);
        var bytes_written: usize = 0;
        var seek_offset = start_seek_offset;

        while (bytes_written < bytes_to_write) {
            const sector = self.physicalFromLogical(seek_offset / fat.sector_size);
            const sentry = scache.get(sector);
            defer scache.put(sentry);

            const size = @min(n - bytes_written, fat.sector_size - seek_offset % fat.sector_size);
            const from = @intFromPtr(&sentry.data) + (seek_offset % fat.sector_size);
            syscall.regionWrite(.self, region_handle, @ptrFromInt(from), region_offset + bytes_written, size) catch break;

            bytes_written += size;
            seek_offset += size;
        }

        self.access_time = rtc.currentDateTime();
        self.flush();

        return bytes_written;
    }

    pub fn write(self: *Entry, start_seek_offset: usize, region_handle: Handle, region_offset: usize, n: usize) usize {
        var bytes_read: usize = 0;
        var seek_offset = start_seek_offset;

        while (bytes_read < n) {
            const sector = self.physicalFromLogical(seek_offset / fat.sector_size);
            const sentry = scache.get(sector);
            defer scache.put(sentry);

            const size = @min(n - bytes_read, fat.sector_size - seek_offset % fat.sector_size);
            const to = @intFromPtr(&sentry.data) + (seek_offset % fat.sector_size);
            syscall.regionRead(.self, region_handle, @ptrFromInt(to), region_offset + bytes_read, size) catch break;
            sentry.state = .dirty;

            bytes_read += size;
            seek_offset += size;
        }

        if (seek_offset > self.size)
            self.size = seek_offset;
        self.modification_time = rtc.currentDateTime();
        self.flush();

        return bytes_read;
    }

    pub fn readdir(self: *Entry, seek_offset: *usize, region_handle: Handle, region_offset: usize, n: usize) usize {
        const region_size = syscall.regionSize(.self, region_handle) catch return 0;
        if (region_size * mem.page_size < (region_offset + n) * @sizeOf(service.directory.Entry))
            return 0;

        const region_ptr = syscall.regionMap(.self, region_handle, null) catch return 0;
        defer _ = syscall.regionUnmap(.self, region_ptr) catch {};

        const directory_entries_start: [*]service.directory.Entry = @ptrCast(region_ptr);
        const directory_entries = directory_entries_start[region_offset .. region_offset + n];

        var entries_read: usize = 0;
        for (directory_entries) |*directory_entry| {
            const fentry = self.getNextChild(seek_offset) orelse break;
            fentry.toDirectoryEntry(directory_entry);
            entries_read += 1;
        }

        self.access_time = rtc.currentDateTime();
        self.flush();

        return entries_read;
    }

    pub fn stat(self: *Entry, region_handle: Handle, region_offset: usize) !void {
        var directory_entry: service.directory.Entry = undefined;
        self.toDirectoryEntry(&directory_entry);
        try syscall.regionWrite(.self, region_handle, &directory_entry, region_offset, @sizeOf(service.directory.Entry));
    }

    fn flush(self: Entry) void {
        if (self.isRootDirectory())
            return;

        const parent = self.getParent() orelse @panic("no parent");
        const sector = parent.physicalFromLogical(self.parent_offset / fat.sector_size);
        const sentry = scache.get(sector);
        defer scache.put(sentry);

        const directory_entry: *fat.DirectoryEntry.Normal = @alignCast(@ptrCast(&sentry.data[self.parent_offset % fat.sector_size]));
        directory_entry.access_date.year = @intCast(self.access_time.year - 1980);
        directory_entry.access_date.month = @intCast(self.access_time.month);
        directory_entry.access_date.day = @intCast(self.access_time.day);

        directory_entry.modification_date.year = @intCast(self.modification_time.year - 1980);
        directory_entry.modification_date.month = @intCast(self.modification_time.month);
        directory_entry.modification_date.day = @intCast(self.modification_time.day);
        directory_entry.modification_time.hour = @intCast(self.modification_time.hours);
        directory_entry.modification_time.minute = @intCast(self.modification_time.minutes);
        directory_entry.modification_time.second = @intCast(self.modification_time.seconds / 2);

        directory_entry.size = @intCast(self.size);
        sentry.state = .dirty;
    }

    fn toDirectoryEntry(self: *Entry, directory_entry: *service.directory.Entry) void {
        const name = self.getName();
        @memcpy(directory_entry.name[0..name.len], name);
        directory_entry.name_length = @intCast(name.len);
        directory_entry.flags.directory = self.kind == .directory;
        @memcpy(mem.asBytes(&directory_entry.creation_time), mem.asBytes(&self.creation_time));
        @memcpy(mem.asBytes(&directory_entry.access_time), mem.asBytes(&self.access_time));
        @memcpy(mem.asBytes(&directory_entry.modification_time), mem.asBytes(&self.modification_time));
        directory_entry.size = @intCast(self.size);
    }

    fn nameHashBucket(parent_start_sector: Sector, child_name: []const u8) *Bucket {
        var hash_state = Wyhash.init(0);
        hash_state.update(mem.asBytes(&parent_start_sector));
        hash_state.update(child_name);
        const hash = hash_state.final();
        return &name_hash_buckets[hash % name_hash_bucket_count];
    }

    fn sectorHashBucket(start_sector: Sector) *Bucket {
        return &sector_hash_buckets[start_sector & sector_hash_mask];
    }

    fn popLruList() *Entry {
        const result = lru_list_head orelse @panic("all cache elements in use");
        lru_list_head = result.lru_list_next;
        if (lru_list_head) |head|
            head.lru_list_prev = null;
        if (result == lru_list_tail)
            lru_list_tail = null;

        result.lru_list_next = null;
        result.lru_list_prev = null;
        result.removeFromSectorHashChain();
        result.removeFromNameHashChain();
        if (result.hasLongName())
            allocator.free(result.long_name);

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

    fn removeFromSectorHashChain(self: *Entry) void {
        const start_sector = self.start_sector orelse return;
        const bucket = sectorHashBucket(start_sector);
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

    fn removeFromNameHashChain(self: *Entry) void {
        const parent_start_sector = self.parent_start_sector orelse return;
        const bucket = nameHashBucket(parent_start_sector, self.getName());
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
var allocator: mem.Allocator = undefined;

pub fn init(root_start_sector: Sector, allocator_: mem.Allocator) *Entry {
    allocator = allocator_;

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
    root_entry.parent_start_sector = null;
    root_entry.kind = .directory;
    root_entry.ref_count = 1;

    const sector_hash_bucket = Entry.sectorHashBucket(root_start_sector);
    root_entry.sector_hash_next = null;
    sector_hash_bucket.* = root_entry;

    return root_entry;
}
