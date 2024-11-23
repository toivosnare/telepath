const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const proc = @import("../proc.zig");
const Hart = proc.Hart;

pub const Plic = extern struct {
    priorities: [source_count]u32,
    pendings: [source_count / 32]u32,
    padding1: [0xf80]u8,
    enables: [context_count][source_count / 32]u32,
    padding2: [0xe000]u8,
    contexts: [context_count]extern struct {
        priority_treshold: u32,
        claim_complete: u32,
        padding: [0xff8]u8,
    },

    const source_count = 1024;
    const context_count = 15872;

    comptime {
        assert(@offsetOf(Plic, "priorities") == 0x0_000);
        assert(@offsetOf(Plic, "pendings") == 0x1_000);
        assert(@offsetOf(Plic, "enables") == 0x2_000);
        assert(@offsetOf(Plic, "contexts") == 0x200_000);
        assert(@sizeOf(Plic) == 0x4_000_000);
    }

    pub fn setPriority(self: *volatile Plic, source: u32, priority: u32) void {
        self.priorities[source] = priority;
    }

    pub fn enable(self: *volatile Plic, hart_id: Hart.Id, source: u32) void {
        const word_index = source / 32;
        const bit_index = source % 32;
        self.enables[hart_id * 2 + 1][word_index] |= (@as(u32, 1) << @intCast(bit_index));
    }

    pub fn disable(self: *volatile Plic, hart_id: Hart.Id, source: u32) void {
        const word_index = source / 32;
        const bit_index = source % 32;
        self.enables[hart_id * 2 + 1][word_index] &= ~(@as(u32, 1) << @intCast(bit_index));
    }

    pub fn setTreshold(self: *volatile Plic, hart_id: Hart.Id, treshold: u32) void {
        self.contexts[hart_id * 2 + 1].priority_treshold = treshold;
    }

    pub fn claim(self: *volatile Plic, hart_id: Hart.Id) u32 {
        return self.contexts[hart_id * 2 + 1].claim_complete;
    }

    pub fn complete(self: *volatile Plic, hart_id: Hart.Id, source: u32) void {
        self.contexts[hart_id * 2 + 1].claim_complete = source;
    }
};
