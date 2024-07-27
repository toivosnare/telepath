const std = @import("std");

pub const KERNEL_STACK_SIZE_PER_HART = 8 * std.mem.page_size;
