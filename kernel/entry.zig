const std = @import("std");

pub const kernel_stack_size_per_hart = 8 * std.mem.page_size;
