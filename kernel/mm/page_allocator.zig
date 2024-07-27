const std = @import("std");
const assert = std.debug.assert;
const mm = @import("../mm.zig");
const log = std.log;
const Page = mm.Page;
const PageSlice = mm.PageSlice;
const PageFrameSlice = mm.PageFrameSlice;
const ConstPageFrameSlice = mm.ConstPageFrameSlice;

const MAX_ORDER = 3;

var buckets: *[MAX_ORDER]Bucket = undefined;
var bitfield: std.PackedIntSlice(u1) = undefined;
var pages: PageSlice = undefined;
var max_nodes: usize = undefined;

const Bucket = struct {
    free_list: Node,
    free_count: usize,
};

const Node = struct {
    const Self = @This();
    prev_offset: usize,
    next_offset: usize,

    pub fn init(self: *Self) void {
        self.prev_offset = 0;
        self.next_offset = 0;
    }

    pub fn append(self: *Self, other: *Self) void {
        const prev = self.getPrev();
        other.setPrev(prev);
        other.setNext(self);
        prev.setNext(other);
        self.setPrev(other);
    }

    pub fn remove(self: *Self) void {
        const prev = self.getPrev();
        const next = self.getNext();
        prev.setNext(next);
        next.setPrev(prev);
    }

    pub fn pop(self: *Self) ?*Self {
        const prev = self.getPrev();
        if (prev == self)
            return null;
        prev.remove();
        return prev;
    }

    pub fn offsetTo(self: *const Self, other: *const Self) usize {
        return @intFromPtr(other) -% @intFromPtr(self);
    }

    pub fn getPrev(self: *const Self) *Self {
        return @ptrFromInt(@intFromPtr(self) +% self.prev_offset);
    }

    pub fn getNext(self: *const Self) *Self {
        return @ptrFromInt(@intFromPtr(self) +% self.next_offset);
    }

    pub fn setPrev(self: *Self, prev: *Self) void {
        self.prev_offset = self.offsetTo(prev);
    }

    pub fn setNext(self: *Self, next: *Self) void {
        self.next_offset = self.offsetTo(next);
    }

    pub fn index(self: *const Self, order: usize) usize {
        const offset = @intFromPtr(self) - @intFromPtr(pages.ptr);
        const region_size = @as(usize, 1) << @intCast(MAX_ORDER - order - 1);
        const page_index = offset / @sizeOf(Page);
        return (region_size - 1) * max_nodes + (page_index >> @intCast(order));
    }

    pub fn parentIndex(self: *const Self, order: usize) usize {
        const self_index = self.index(order);
        return (self_index - max_nodes) / 2;
    }

    pub fn parent(self: *const Self, order: usize) *Self {
        const offset = @intFromPtr(self) - @intFromPtr(pages.ptr);
        const region_size = @as(usize, 1) << @intCast(order + std.math.log2(@sizeOf(Page)) + 1);
        const parent_offset = offset & ~(region_size - 1);
        return @ptrFromInt(parent_offset + @intFromPtr(pages.ptr));
    }

    pub fn buddy(self: *const Self, order: usize) *Self {
        const offset = @intFromPtr(self) - @intFromPtr(pages.ptr);
        const region_size = @as(usize, 1) << @intCast(order + std.math.log2(@sizeOf(Page)));
        const buddy_offset = offset ^ region_size;
        return @ptrFromInt(buddy_offset + @intFromPtr(pages.ptr));
    }

    pub fn flip(self: *const Self, order: usize) bool {
        const parent_index = self.parentIndex(order);
        const old_value = bitfield.get(parent_index);
        const new_value = old_value ^ 1;
        bitfield.set(parent_index, new_value);
        return new_value == 1;
    }
};

// TODO: bitfield might overlap with the holes?
// TODO: there might be a case where max_nodes must be decremented by one?
pub fn init(heap: PageFrameSlice, holes: []const ConstPageFrameSlice) void {
    log.info("Initializing page allocator.", .{});
    const MAX_NODE_PAGES = 1 << (MAX_ORDER - 1);
    const heap_pages = std.mem.alignBackward(usize, heap.len, MAX_NODE_PAGES);
    max_nodes = heap_pages / MAX_NODE_PAGES;

    const buckets_bytes = @sizeOf(Bucket) * MAX_ORDER;
    const buckets_bits = buckets_bytes * 8;
    const bitfield_bits = ((1 << (MAX_ORDER - 1)) - 1) * max_nodes;
    const metadata_bits = buckets_bits + bitfield_bits;
    const metadata_pages = std.math.divCeil(usize, metadata_bits, @sizeOf(Page) * 8) catch unreachable;

    buckets = @ptrCast(heap.ptr);
    for (buckets) |*bucket| {
        bucket.free_list.init();
        bucket.free_count = 0;
    }
    const bitfield_bytes = std.mem.sliceAsBytes(heap[0..metadata_pages])[buckets_bytes..];
    bitfield = std.PackedIntSlice(u1).init(bitfield_bytes, bitfield_bits);
    pages = heap[metadata_pages..];

    const max_order_bucket = &buckets[MAX_ORDER - 1];
    var start: usize = 0;
    var end: usize = MAX_NODE_PAGES;
    while (end <= pages.len) {
        const slice = pages[start..end];
        for (holes) |hole| {
            if (mm.pageSlicesOverlap(slice, hole))
                break;
        } else {
            const node: *Node = @ptrCast(slice);
            max_order_bucket.free_list.append(node);
            max_order_bucket.free_count += 1;
        }
        start = end;
        end += MAX_NODE_PAGES;
    }
}

pub fn allocate(requested_order: usize) !PageSlice {
    log.debug("Allocating node of order {}.", .{requested_order});
    var order = requested_order;
    const node: *Node = while (order < MAX_ORDER) : (order += 1) {
        if (buckets[order].free_list.pop()) |node|
            break node;
    } else {
        return error.OutOfMemory;
    };
    buckets[order].free_count -= 1;

    while (true) {
        if (order < MAX_ORDER - 1)
            _ = node.flip(order);
        if (order == requested_order)
            break;

        order -= 1;
        buckets[order].free_list.append(node.buddy(order));
        buckets[order].free_count += 1;
    }

    var result: PageSlice = undefined;
    result.ptr = @alignCast(@ptrCast(node));
    result.len = @as(usize, 1) << @intCast(requested_order);
    return result;
}

pub fn free(slice: PageSlice) void {
    assert(std.math.isPowerOfTwo(slice.len));
    var order = std.math.log2(slice.len);
    var node: *Node = @ptrCast(slice.ptr);
    log.debug("Freeing node {*} of order {}.", .{ node, order });

    while (order < MAX_ORDER - 1) : (order += 1) {
        if (node.flip(order))
            break;
        node.buddy(order).remove();
        buckets[order].free_count -= 1;
        node = node.parent(order);
    }

    buckets[order].free_list.append(node);
    buckets[order].free_count += 1;
}

pub fn dump() void {
    log.debug("Page allocator status:", .{});
    for (0.., buckets) |order, *bucket| {
        log.debug("Order {} free count {}", .{ order, bucket.free_count });
        const head = &bucket.free_list;
        var node: *Node = head.getNext();
        while (node != head) : (node = node.getNext()) {
            log.debug("\t{*}", .{node});
        }
    }

    log.debug("Bitfield:", .{});
    for (0..bitfield.len) |i| {
        log.debug("\t{}", .{bitfield.get(i)});
    }
}

pub fn onAddressTranslationEnabled() void {
    buckets = @ptrFromInt(mm.logicalFromPhysical(@intFromPtr(buckets)));
    bitfield.bytes.ptr = @ptrFromInt(mm.logicalFromPhysical(@intFromPtr(bitfield.bytes.ptr)));
    pages.ptr = @ptrFromInt(mm.logicalFromPhysical(@intFromPtr(pages.ptr)));
    log.debug("buckets : {*}, bitfield : {*}, pages : {*}", .{ buckets, bitfield.bytes, pages });
}
