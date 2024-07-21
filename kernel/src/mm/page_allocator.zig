const std = @import("std");
const assert = std.debug.assert;
const mm = @import("../mm.zig");
const log = std.log;
const PageFrame = mm.PageFrame;
const PageFrameSlice = mm.PageFrameSlice;
const ConstPageFrameSlice = mm.ConstPageFrameSlice;

const MAX_ORDER = 3;

var buckets: *[MAX_ORDER]Bucket = undefined;
var bitfield: std.PackedIntSlice(u1) = undefined;
var pages: PageFrameSlice = undefined;
var max_nodes: usize = undefined;

const Bucket = struct {
    free_list: Node,
    free_count: usize,
};

const Node = struct {
    const Self = @This();
    prev: *Self,
    next: *Self,

    pub fn index(self: *Self, order: usize) usize {
        const offset = @intFromPtr(self) - @intFromPtr(pages.ptr);
        const region_size = @as(usize, 1) << @intCast(MAX_ORDER - order - 1);
        const page_index = offset / mm.PAGE_SIZE;
        return (region_size - 1) * max_nodes + (page_index >> @intCast(order));
    }

    pub fn parentIndex(self: *Self, order: usize) usize {
        const self_index = self.index(order);
        return (self_index - max_nodes) / 2;
    }

    pub fn parent(self: *Self, order: usize) *Self {
        const offset = @intFromPtr(self) - @intFromPtr(pages.ptr);
        const region_size = @as(usize, 1) << @intCast(order + std.math.log2(mm.PAGE_SIZE) + 1);
        const parent_offset = offset & ~(region_size - 1);
        return @ptrFromInt(parent_offset + @intFromPtr(pages.ptr));
    }

    pub fn buddy(self: *Self, order: usize) *Self {
        const offset = @intFromPtr(self) - @intFromPtr(pages.ptr);
        const region_size = @as(usize, 1) << @intCast(order + std.math.log2(mm.PAGE_SIZE));
        const buddy_offset = offset ^ region_size;
        return @ptrFromInt(buddy_offset + @intFromPtr(pages.ptr));
    }

    pub fn flip(self: *Self, order: usize) bool {
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
    const metadata_pages = std.math.divCeil(usize, metadata_bits, mm.PAGE_SIZE * 8) catch unreachable;

    buckets = @ptrCast(heap.ptr);
    for (buckets) |*bucket| {
        listInit(&bucket.free_list);
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
            // if (mm.pageFrameSlicesOverlap(slice, hole))
            //     break;
            _ = hole;
        } else {
            const node: *Node = @ptrCast(slice);
            listPush(&max_order_bucket.free_list, node);
            max_order_bucket.free_count += 1;
        }
        start = end;
        end += MAX_NODE_PAGES;
    }
}

pub fn allocate(requested_order: usize) !PageFrameSlice {
    log.debug("Allocating node of order {}.", .{requested_order});
    var order = requested_order;
    const node: *Node = while (order < MAX_ORDER) : (order += 1) {
        if (listPop(&buckets[order].free_list)) |node|
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
        buckets[order].free_count += 1;
        listPush(&buckets[order].free_list, node.buddy(order));
    }

    var result: PageFrameSlice = undefined;
    result.ptr = @alignCast(@ptrCast(node));
    result.len = @as(usize, 1) << @intCast(requested_order);
    return result;
}

pub fn free(slice: PageFrameSlice) void {
    assert(std.math.isPowerOfTwo(slice.len));
    var order = std.math.log2(slice.len);
    var node: *Node = @ptrCast(slice.ptr);
    log.debug("Freeing node {*} of order {}.", .{ node, order });

    while (order < MAX_ORDER - 1) : (order += 1) {
        if (node.flip(order))
            break;
        listRemove(node.buddy(order));
        buckets[order].free_count -= 1;
        node = node.parent(order);
    }

    listPush(&buckets[order].free_list, node);
    buckets[order].free_count += 1;
}

pub fn dump() void {
    log.debug("Page allocator status:", .{});
    for (0.., buckets) |order, *bucket| {
        log.debug("Order {} free count {}", .{ order, bucket.free_count });
        const head = &bucket.free_list;
        var node: *Node = head.next;
        while (node != head) : (node = node.next) {
            log.debug("\t{*}", .{node});
        }
    }

    log.debug("Bitfield:", .{});
    for (0..bitfield.len) |i| {
        log.debug("\t{}", .{bitfield.get(i)});
    }
}

fn listInit(list: *Node) void {
    list.prev = list;
    list.next = list;
}

fn listPush(list: *Node, node: *Node) void {
    const prev = list.prev;
    node.prev = prev;
    node.next = list;
    prev.next = node;
    list.prev = node;
}

fn listRemove(node: *Node) void {
    const prev = node.prev;
    const next = node.next;
    prev.next = next;
    next.prev = prev;
}

fn listPop(list: *Node) ?*Node {
    const prev = list.prev;
    if (prev == list)
        return null;
    listRemove(prev);
    return prev;
}
