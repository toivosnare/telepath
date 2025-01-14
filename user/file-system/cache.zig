const std = @import("std");
const log = std.log;
const math = std.math;
const libt = @import("libt");
const syscall = libt.syscall;
const Spinlock = libt.sync.Spinlock;
const services = @import("services");
const block = services.block;

const n = 8;
const hash_bucket_count = 1 << n;
const hash_mask: usize = hash_bucket_count - 1;
const entry_count = 128;

var lock: Spinlock = .{};
var hash_buckets: [hash_bucket_count]?*Entry = undefined;
var lru_list_head: ?*Entry = null;
var lru_list_tail: ?*Entry = null;
var entries: [entry_count]Entry = undefined;
var entries_physical_base: usize = undefined;

pub const Entry = struct {
    sector_index: usize,
    data: [sector_size]u8,
    state: State,
    ref_count: u8,
    hash_chain_next: ?*Entry,
    lru_list_next: ?*Entry,
    lru_list_prev: ?*Entry,

    pub const State = enum(u32) {
        clean,
        dirty,
        fetching,
    };

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
                self.hash_chain_next = null;
                return;
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

        result.lru_list_next = null;
        result.lru_list_prev = null;
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
    lock.lock();

    const bucket = &hash_buckets[sector_index & hash_mask];
    var entry = bucket.*;
    while (entry) |e| : (entry = e.hash_chain_next) {
        if (e.sector_index == sector_index) {
            e.ref_count += 1;

            if (e.state == .fetching) {
                lock.unlock();
                libt.waitFutex(@ptrCast(&e.state), @intFromEnum(Entry.State.fetching), math.maxInt(usize)) catch @panic("wait error");
            } else {
                e.removeFromLruList();
                lock.unlock();
            }
            return e;
        }
    }

    const evided_entry = Entry.popLruList();
    evided_entry.removeFromHashChain();

    const physical_address = @intFromPtr(evided_entry) - @intFromPtr(&entries) + entries_physical_base + @offsetOf(Entry, "data");

    if (evided_entry.state == .dirty) {
        @panic("dirty");
    }

    evided_entry.sector_index = sector_index;
    evided_entry.state = .fetching;
    evided_entry.ref_count = 1;

    // Add to hash chain.
    evided_entry.hash_chain_next = bucket.*;
    bucket.* = evided_entry;

    lock.unlock();

    block.request.write(.{
        .sector_index = sector_index,
        .address = physical_address,
        .write = false,
        .token = @intFromPtr(evided_entry),
    });
    libt.waitFutex(@ptrCast(&evided_entry.state), @intFromEnum(Entry.State.fetching), math.maxInt(usize)) catch @panic("wait error");

    return evided_entry;
}

pub fn returnSector(entry: *Entry) void {
    lock.lock();
    defer lock.unlock();

    entry.ref_count -= 1;
    if (entry.ref_count > 0)
        return;
    entry.addToLruList();
}

pub fn loop() noreturn {
    while (true) {
        const response = block.response.read();

        lock.lock();
        const entry: *Entry = @ptrFromInt(response.token);
        entry.state = .clean;
        lock.unlock();

        _ = syscall.wake(@ptrCast(&entry.state), math.maxInt(usize)) catch @panic("wake error");
    }
}
