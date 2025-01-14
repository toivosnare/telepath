const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const mem = std.mem;
const libt = @import("libt");
const syscall = libt.syscall;
const virtio = @import("virtio.zig");
const Status = virtio.MmioRegisters.Status;
const services = @import("services");

comptime {
    _ = libt;
}

const Config = extern struct {
    capacity: u64,
    size_max: u32,
    seg_max: u32,
    geometry: extern struct {
        cylinders: u16,
        heads: u8,
        sectors: u8,
    },
    blk_size: u32,
    topology: extern struct {
        physical_block_exp: u8,
        alignment_offset: u8,
        min_io_size: u16,
        opt_io_size: u32,
    },
    writeback: u8,
    unused0: u8,
    num_queues: u16,
    max_discard_sectors: u32,
    max_discard_seg: u32,
    discard_sector_alignment: u32,
    max_write_zeroes_sectors: u32,
    max_write_zeroes_seg: u32,
    write_zeroes_may_unmap: u8,
    unused1: [3]u8,
    max_secure_erase_sectors: u32,
    max_secure_erase_seg: u32,
    secure_erase_sector_alignment: u32,
};

const Request = extern struct {
    type: enum(u32) {
        in = 0,
        out = 1,
    },
    reserved: u32 = 0,
    sector_index: u64,
    token: usize,
    status: u8,

    pub fn send(sector_index: usize, address: usize, write: bool, token: usize, regs: *volatile virtio.MmioRegisters) !void {
        const idx = try allocateDescriptors();

        const request = &requests[idx[0]];
        request.type = if (write) .out else .in;
        request.sector_index = sector_index;
        request.token = token;
        request.status = 22;

        const d0 = &queue.descriptors[idx[0]];
        d0.address = request.basePhysicalAddress();
        d0.length = 16;
        d0.flags = .{ .next = true };
        d0.next = idx[1];

        const d1 = &queue.descriptors[idx[1]];
        d1.address = address;
        d1.length = 512;
        d1.flags = .{ .next = true, .write = !write };
        d1.next = idx[2];

        const d2 = &queue.descriptors[idx[2]];
        d2.address = request.statusPhysicalAddress();
        d2.length = 1;
        d2.flags = .{ .write = true };
        d2.next = Queue.chain_end;

        queue.available.ring[queue.available.index % Queue.length] = idx[0];
        // @fence(.seq_cst);
        queue.available.index += 1;
        // @fence(.seq_cst);
        regs.queue_notify.index = 0;
    }

    fn basePhysicalAddress(self: *const Request) usize {
        return @intFromPtr(self) - @intFromPtr(&requests) + requests_physical_address;
    }

    fn statusPhysicalAddress(self: *const Request) usize {
        return self.basePhysicalAddress() + @offsetOf(Request, "status");
    }
};

const interrupt_source = 0x08;
const Queue = virtio.Queue(8);
var queue: Queue = undefined;
var requests: [Queue.length]Request = undefined;
var requests_physical_address: usize = undefined;

pub fn main(args: []usize) !usize {
    _ = args;
    const writer = services.serial.tx.writer();
    try writer.writeAll("Initializing virtio-blk driver.\n");

    const physical_address = 0x10008000;
    const region_size = math.divCeil(usize, @sizeOf(virtio.MmioRegisters) + @sizeOf(Config), mem.page_size) catch unreachable;
    const region = syscall.regionAllocate(.self, region_size, .{ .read = true, .write = true }, @ptrFromInt(physical_address)) catch unreachable;
    const regs: *volatile virtio.MmioRegisters = @ptrCast(syscall.regionMap(.self, region, null) catch unreachable);

    if (regs.magic_value != virtio.MmioRegisters.magic) {
        try writer.writeAll("Invalid magic value.\n");
        return 1;
    }

    if (regs.version != 2) {
        try writer.writeAll("Invalid version.\n");
        return 2;
    }

    if (regs.device_id != .block_device) {
        try writer.writeAll("Invalid device id.\n");
        return 3;
    }

    regs.status = 0;
    regs.status |= @intFromEnum(Status.acknowledge);
    regs.status |= @intFromEnum(Status.driver);

    _ = regs.device_features;
    const selected_features: u32 = 0;
    regs.driver_features = selected_features;
    regs.status |= @intFromEnum(Status.features_ok);

    if (regs.status & @intFromEnum(virtio.MmioRegisters.Status.features_ok) == 0) {
        try writer.writeAll("Features not supported.\n");
        return 4;
    }

    regs.queue_sel = 0;
    if (regs.queue_ready != 0) {
        try writer.writeAll("Queue should not be ready.\n");
        return 5;
    }

    const queue_num_max = regs.queue_num_max;
    if (queue_num_max == 0) {
        try writer.writeAll("Max queue size is 0.\n");
        return 6;
    }
    if (queue_num_max < Queue.length) {
        try writer.writeAll("Max queue size is too small.\n");
        return 7;
    }
    regs.queue_num = Queue.length;

    const physical_base = @intFromPtr(syscall.processTranslate(.self, &queue) catch unreachable);

    const descriptors = physical_base + @offsetOf(Queue, "descriptors");
    regs.queue_desc_low = @intCast(descriptors & 0xFFFFFFFF);
    regs.queue_desc_high = @intCast(descriptors >> 32);

    const available = physical_base + @offsetOf(Queue, "available");
    regs.queue_driver_low = @intCast(available & 0xFFFFFFFF);
    regs.queue_driver_high = @intCast(available >> 32);

    const used = physical_base + @offsetOf(Queue, "used");
    regs.queue_device_low = @intCast(used & 0xFFFFFFFF);
    regs.queue_device_high = @intCast(used >> 32);

    regs.queue_ready = 1;

    regs.status |= @intFromEnum(Status.driver_ok);

    queue.init();

    requests_physical_address = @intFromPtr(syscall.processTranslate(.self, &requests) catch unreachable);

    const client = services.client;
    const request_channel = &client.request;
    const response_channel = &client.response;
    const request_channel_index = 0;
    const interrupt_index = 1;

    var wait_reasons: [2]syscall.WaitReason = .{
        .{ .tag = .futex, .payload = .{ .futex = .{ .address = &request_channel.empty.state, .expected_value = undefined } } },
        .{ .tag = .interrupt, .payload = .{ .interrupt = interrupt_source } },
    };
    var used_idx: u16 = 0;

    outer: while (true) {
        request_channel.mutex.lock();
        while (request_channel.length > 0) {
            const request = &request_channel.buffer[request_channel.read_index];
            Request.send(request.sector_index, request.address, request.write, request.token, regs) catch {
                response_channel.write(.{
                    .success = false,
                    .token = request.token,
                });
            };
            request_channel.read_index = (request_channel.read_index + 1) % @typeInfo(@TypeOf(response_channel)).Pointer.child.capacity;
            request_channel.length -= 1;
            request_channel.full.notify(.one);
        }

        const old_state = request_channel.empty.state.load(.monotonic);
        request_channel.mutex.unlock();
        wait_reasons[request_channel_index].payload.futex.expected_value = old_state;

        while (true) {
            const index = syscall.wait(&wait_reasons, math.maxInt(usize)) catch unreachable;
            if (index == request_channel_index) {
                syscall.unpackResult(syscall.WaitError!void, wait_reasons[request_channel_index].result) catch |err| switch (err) {
                    error.WouldBlock => {},
                    else => @panic("wait errror"),
                };
                continue :outer;
            } else {
                assert(index == interrupt_index);
                assert(syscall.unpackResult(syscall.WaitError!usize, wait_reasons[interrupt_index].result) catch 1 == 0);

                regs.interrupt_acknowledge = @bitCast(regs.interrupt_status);
                syscall.ack(interrupt_source) catch unreachable;

                while (used_idx != queue.used.index) : (used_idx += 1) {
                    const chain_index: Queue.Index = @intCast(queue.used.ring[used_idx % Queue.length].id);
                    const request = &requests[chain_index];
                    freeDescriptors(chain_index);
                    response_channel.write(.{
                        .success = request.status == 0,
                        .token = request.token,
                    });
                }
            }
        }
    }
}

fn allocateDescriptors() ![3]Queue.Index {
    var result: [3]Queue.Index = undefined;
    var i: usize = 0;

    errdefer {
        for (result[0..i]) |index|
            queue.free(index);
    }

    while (i < 3) : (i += 1)
        result[i] = try queue.allocate();

    return result;
}

fn freeDescriptors(chain: Queue.Index) void {
    const d0 = &queue.descriptors[chain];
    const d1 = &queue.descriptors[d0.next];
    const d2 = &queue.descriptors[d1.next];
    d2.next = queue.free_list_head;
    queue.free_list_head = chain;
}
