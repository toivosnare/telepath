const mm = @import("../mm.zig");
const PageFramePtr = mm.PageFramePtr;
const PageFrameSlice = mm.PageFrameSlice;
const Region = @This();

// Ref count of zero implies that the region is not in use.
ref_count: usize,
page_frame_count: usize,
page_frames: [MAX_PAGE_FRAMES]PageFramePtr,

const MAX_PAGE_FRAMES = 16;
const MAX_REGIONS = 128;

var regions: [MAX_REGIONS]Region = undefined;

pub fn init() void {
    for (&regions) |*r| {
        r.ref_count = 0;
    }
}

pub fn allocate() !*Region {
    for (&regions) |*r| {
        if (r.isFree()) {
            r.ref_count = 1;
            r.page_frame_count = 0;
            return r;
        }
    }
    return error.RegionTableFull;
}

pub fn free(self: *Region) void {
    self.ref_count = 0;
}

pub fn isFree(self: Region) bool {
    return self.ref_count == 0;
}

pub fn addPageFrame(self: *Region, page_frame: PageFramePtr) !void {
    if (self.page_frame_count == MAX_PAGE_FRAMES)
        return error.PageFrameTableFull;
    self.page_frames[self.page_frame_count] = page_frame;
    self.page_frame_count += 1;
}

pub fn addPageFrames(self: *Region, page_frames: PageFrameSlice) !void {
    if (self.page_frame_count + page_frames.len > MAX_PAGE_FRAMES)
        return error.PageFrameTableFull;
    for (page_frames) |*pf|
        try self.addPageFrame(pf);
}
