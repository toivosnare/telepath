const libt = @import("libt");
const services = @import("services");
const block = services.block;

const n = 8;
const hash_bucket_count = 1 << n;
const hash_mask: usize = hash_bucket_count - 1;
const entry_count = 128;

var hash_buckets: [hash_bucket_count]?*Entry = undefined;
var lru_list_head: ?*Entry = null;
var lru_list_tail: ?*Entry = null;
var entries: [entry_count]Entry = undefined;
var entries_physical_base: usize = undefined;

pub const Entry = struct {
    sector_index: usize,
    data: [sector_size]u8,
    state: enum {
        clean,
        dirty,
    },
    ref_count: u8,
    hash_chain_next: ?*Entry,
    lru_list_next: ?*Entry,
    lru_list_prev: ?*Entry,

    pub const sector_size = 512;

    pub fn removeFromLruList(self: *Entry) void {
        if (self.lru_list_prev) |prev|
            prev.lru_list_next = self.lru_list_next
        else if (lru_list_head == self)
            lru_list_head = self.lru_list_next;

        if (self.lru_list_next) |next|
            next.lru_list_prev = self.lru_list_prev
        else if (lru_list_tail == self)
            lru_list_tail = self.lru_list_prev;
    }

    pub fn removeFromHashChain(self: *Entry) void {
        const bucket = &hash_buckets[self.sector_index & hash_mask];
        var prev_entry: ?*Entry = null;
        var entry = bucket.*;
        while (entry) |e| {
            if (e == self) {
                if (prev_entry) |prev|
                    prev.hash_chain_next = self.hash_chain_next
                else
                    bucket.* = self.hash_chain_next;
                break;
            }
            prev_entry = entry;
            entry = e.hash_chain_next;
        }
    }

    pub fn addToLruList(self: *Entry) void {
        if (lru_list_tail) |tail| {
            tail.lru_list_next = self;
        } else {
            lru_list_head = self;
        }
        self.lru_list_prev = lru_list_tail;
        self.lru_list_next = null;
        lru_list_tail = self;
    }

    pub fn popLruList() *Entry {
        const result = lru_list_head orelse @panic("all cache elements in use");
        lru_list_head = result.lru_list_next;
        if (lru_list_head) |head|
            head.lru_list_prev = null;
        if (result == lru_list_tail)
            lru_list_tail = null;
        return result;
    }
};

pub fn init() void {
    for (&hash_buckets) |*bucket| {
        bucket.* = null;
    }

    var prev: ?*Entry = null;
    for (&entries) |*entry| {
        entry.sector_index = 0;
        entry.state = .clean;
        entry.ref_count = 0;
        entry.hash_chain_next = null;
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

    entries_physical_base = @intFromPtr(libt.syscall.processTranslate(.self, &entries) catch unreachable);
}

pub fn getSector(sector_index: usize) *Entry {
    const bucket = &hash_buckets[sector_index & hash_mask];
    var entry = bucket.*;
    while (entry) |e| : (entry = e.hash_chain_next) {
        if (e.sector_index == sector_index) {
            e.removeFromLruList();
            return e;
        }
    }

    const evided_entry = Entry.popLruList();
    evided_entry.removeFromHashChain();

    if (evided_entry.state == .dirty) {
        @panic("dirty");
    }

    const physical_address = @intFromPtr(evided_entry) - @intFromPtr(&entries) + entries_physical_base + @offsetOf(Entry, "data");
    block.request.write(.{
        .sector = sector,
        .address = physical_address,
        .write = false,
        .token = 0,
    });
    _ = block.response.read();

    evided_entry.sector = sector;
    evided_entry.state = .clean;
    evided_entry.ref_count = 1;
    evided_entry.hash_chain_next = bucket.*;
    bucket.* = evided_entry;
    return evided_entry;
}

pub fn returnSector(entry: *Entry) void {
    entry.ref_count -= 1;
    if (entry.ref_count > 0)
        return;
    entry.addToLruList();
}
