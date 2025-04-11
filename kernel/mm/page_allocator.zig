const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const mem = std.mem;
const log = std.log.scoped(.@"mm.page_allocator");
const libt = @import("libt");
const Spinlock = libt.sync.Spinlock;
const mm = @import("../mm.zig");
const Page = mm.Page;
const PageSlice = mm.PageSlice;
const PageFrameSlice = mm.PageFrameSlice;

pub const max_order = 13;
pub const max_order_pages = 1 << (max_order - 1);

var buckets: *[max_order]Bucket = undefined;
var bitfield: []u8 = undefined;
var pages: PageSlice = undefined;
var max_nodes: usize = undefined;
var lock: Spinlock = .{};

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
        const region_size = @as(usize, 1) << @intCast(max_order - order - 1);
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
        const old_value = mem.readPackedIntNative(u1, bitfield, parent_index);
        const new_value = old_value ^ 1;
        mem.writePackedIntNative(u1, bitfield, parent_index, new_value);
        return new_value == 1;
    }
};

// FIXME: bitfield might overlap with the holes?
// FIXME: there might be a case where max_nodes must be decremented by one?
pub fn init(
    heap: PageFrameSlice,
    tix: PageFrameSlice,
    fdt: PageFrameSlice,
    out_tix_allocations: *PageSlice,
    out_fdt_allocations: *PageSlice,
) void {
    log.info("Initializing page allocator", .{});
    const heap_pages = std.mem.alignBackward(usize, heap.len, max_order_pages);
    max_nodes = heap_pages / max_order_pages;

    const buckets_bytes = @sizeOf(Bucket) * max_order;
    const buckets_bits = buckets_bytes * 8;
    const bitfield_bits = ((1 << (max_order - 1)) - 1) * max_nodes;
    const metadata_bits = buckets_bits + bitfield_bits;
    const metadata_pages = std.math.divCeil(usize, metadata_bits, @sizeOf(Page) * 8) catch unreachable;

    buckets = @ptrCast(heap.ptr);
    for (buckets) |*bucket| {
        bucket.free_list.init();
        bucket.free_count = 0;
    }
    bitfield = mem.sliceAsBytes(heap[0..metadata_pages])[buckets_bytes..];
    pages = heap[metadata_pages..];

    log.info("Total free memory is {}", .{fmt.fmtIntSizeBin(pages.len * @sizeOf(Page))});

    out_tix_allocations.len = 0;
    out_fdt_allocations.len = 0;

    var start: usize = 0;
    var end: usize = max_order_pages;
    while (end <= pages.len) {
        const slice = pages[start..end];
        if (mm.pageSlicesOverlap(slice, tix)) {
            if (out_tix_allocations.len == 0)
                out_tix_allocations.ptr = slice.ptr;
            out_tix_allocations.len += max_order_pages;
        } else if (mm.pageSlicesOverlap(slice, fdt)) {
            if (out_fdt_allocations.len == 0)
                out_fdt_allocations.ptr = slice.ptr;
            out_fdt_allocations.len += max_order_pages;
        } else {
            free(slice);
        }
        start = end;
        end += max_order_pages;
    }
}

pub fn allocate(requested_order: usize) !PageSlice {
    lock.lock();
    defer lock.unlock();

    log.debug("Allocating node of order {d}", .{requested_order});
    var order = requested_order;
    const node: *Node = while (order < max_order) : (order += 1) {
        if (buckets[order].free_list.pop()) |node|
            break node;
    } else {
        log.warn("Could not allocate node of order {d}", .{requested_order});
        return error.OutOfMemory;
    };
    buckets[order].free_count -= 1;

    while (true) {
        if (order < max_order - 1)
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
    @memset(mem.sliceAsBytes(result), 0);
    return result;
}

pub fn free(slice: PageSlice) void {
    lock.lock();
    defer lock.unlock();

    assert(std.math.isPowerOfTwo(slice.len));
    var order = std.math.log2(slice.len);
    var node: *Node = @ptrCast(slice.ptr);
    log.debug("Freeing node {*} of order {d}", .{ node, order });

    while (order < max_order - 1) : (order += 1) {
        if (node.flip(order))
            break;
        node.buddy(order).remove();
        buckets[order].free_count -= 1;
        node = node.parent(order);
    }

    buckets[order].free_list.append(node);
    buckets[order].free_count += 1;
}

pub fn onAddressTranslationEnabled() void {
    buckets = mm.logicalFromPhysical(buckets);
    bitfield.ptr = mm.logicalFromPhysical(bitfield.ptr);
    pages.ptr = mm.logicalFromPhysical(pages.ptr);
}
