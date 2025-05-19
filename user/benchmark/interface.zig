const std = @import("std");
const atomic = std.atomic;
const libt = @import("libt");
const service = libt.service;
const Handle = libt.Handle;

pub const client_count = 4;
pub const sample_count = 100_000;
pub const message_size = 1;

pub const Control = extern struct {
    register: service.Rpc(Handle, void, .none),
    ready_count: atomic.Value(usize),
    finished_count: atomic.Value(usize),
    samples: [client_count][sample_count]u32,
};

pub const Data = service.Rpc([message_size]usize, [message_size]usize, .none);
