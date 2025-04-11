const std = @import("std");
const datetime = @import("datetime").datetime;
const libt = @import("libt");
const syscall = libt.syscall;
const service = libt.service;
const Channel = service.Channel;
const RtcDriver = service.RtcDriver;
const services = @import("services");

comptime {
    _ = libt;
}

pub const std_options = libt.std_options;

const GoldfishRtc = extern struct {
    time_low: u32,
    time_high: u32,
    alarm_low: u32,
    alarm_high: u32,
    irq_enabled: u32,
    clear_alarm: u32,
    alarm_status: u32,
    clear_interrupt: u32,

    pub fn read(self: *const volatile GoldfishRtc) u64 {
        const low = self.time_low;
        const high = self.time_high;
        return (@as(u64, @intCast(high)) << 32) | low;
    }
};

const Client = extern struct {
    request: Channel(RtcDriver.Request, RtcDriver.channel_capacity, .receive),
    response: Channel(RtcDriver.Response, RtcDriver.channel_capacity, .transmit),
};

pub fn main(args: []usize) !void {
    _ = args;

    const serial_driver = services.serial_driver;
    const client: *Client = @ptrCast(services.client);
    const writer = serial_driver.tx.writer();
    try writer.writeAll("Initializing goldfish-rtc driver.\n");

    const physical_address = 0x101000;
    // const interrupt_source = 0x0b;
    const region = syscall.regionAllocate(.self, 1, .{ .read = true, .write = true }, @ptrFromInt(physical_address)) catch unreachable;
    const goldfish: *volatile GoldfishRtc = @ptrCast(syscall.regionMap(.self, region, null) catch unreachable);

    while (true) {
        const request = client.request.read();
        const payload: RtcDriver.Response.Payload = switch (request.op) {
            .timestamp => .{ .timestamp = timestamp(goldfish) },
            .date_time => .{ .date_time = dateTime(goldfish) },
        };
        client.response.write(.{
            .token = request.token,
            .op = request.op,
            .payload = payload,
        });
    }
}

fn timestamp(goldfish: *volatile GoldfishRtc) RtcDriver.Response.Timestamp {
    return goldfish.read();
}

fn dateTime(goldfish: *volatile GoldfishRtc) RtcDriver.Response.DateTime {
    const time: isize = @intCast(goldfish.read() / std.time.ns_per_ms);
    const lib_date_time = datetime.Datetime.fromTimestamp(time);
    return .{
        .year = lib_date_time.date.year,
        .month = lib_date_time.date.month,
        .day = lib_date_time.date.day,
        .hours = lib_date_time.time.hour,
        .minutes = lib_date_time.time.minute,
        .seconds = lib_date_time.time.second,
    };
}
