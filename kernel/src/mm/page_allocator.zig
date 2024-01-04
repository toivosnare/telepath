const log = @import("std").log;
const mm = @import("../mm.zig");
const PageFramePtr = mm.PageFramePtr;
const PageFrameSlice = mm.PageFrameSlice;
const ConstPageFrameSlice = mm.ConstPageFrameSlice;
const PAGE_SIZE = mm.PAGE_SIZE;

pub fn allocate() !PageFramePtr {
    if (free_list_head) |h| {
        free_list_head = h.next;
        free_list_size -= 1;
        log.debug("Allocated page {*}", .{@as(PageFramePtr, @ptrCast(h))});
        return @ptrCast(h);
    } else {
        return error.OutOfMemory;
    }
}

pub fn free(page_frame: PageFramePtr) void {
    var node: *align(PAGE_SIZE) Node = @ptrCast(page_frame);
    node.next = free_list_head;
    free_list_head = node;
    free_list_size += 1;
}

pub fn freeSlice(page_frames: PageFrameSlice) void {
    for (page_frames) |*pf|
        free(pf);
}

pub fn init(heap: PageFrameSlice, fdt: ConstPageFrameSlice, initrd: ConstPageFrameSlice) void {
    log.info("Initializing page allocator.", .{});
    for (heap) |*pf| {
        if (mm.pageFrameOverlapsSlice(pf, fdt)) {
            log.debug("Page frame {*} overlaps with the FDT.", .{pf});
            continue;
        }
        if (mm.pageFrameOverlapsSlice(pf, initrd)) {
            log.debug("Page frame {*} overlaps with the initrd.", .{pf});
            continue;
        }
        free(pf);
    }
    log.debug("free_list_head: {?*}", .{free_list_head});
}

const Node = struct {
    next: ?*align(PAGE_SIZE) Node,
};
var free_list_head: ?*align(PAGE_SIZE) Node = null;
var free_list_size: usize = 0;
