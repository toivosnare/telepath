const std = @import("std");
const meta = std.meta;

pub const stvec = Csr("stvec", packed struct(u64) {
    mode: enum(u2) {
        direct = 0,
        vectored = 1,
        _,
    },
    base: u62,
});

pub const sie = Csr("sie", packed struct(u64) {
    _rsw0: u1 = 0,
    ssie: bool,
    _rsw1: u3 = 0,
    stie: bool,
    _rsw2: u3 = 0,
    seie: bool,
    _rsw3: u3 = 0,
    lcofie: bool,
    _rsw4: u50 = 0,
});

pub const sip = Csr("sip", packed struct(u64) {
    _rsw0: u1 = 0,
    ssip: bool,
    _rsw1: u3 = 0,
    stip: bool,
    _rsw2: u3 = 0,
    seip: bool,
    _rsw3: u3 = 0,
    lcofip: bool,
    _rsw4: u50 = 0,
});

pub const sstatus = Csr("sstatus", packed struct(u64) {
    _rsw0: u1 = 0,
    sie: bool,
    _rsw1: u3 = 0,
    spie: bool,
    ube: bool,
    _rsw2: u1 = 0,
    spp: enum(u1) {
        user = 0,
        supervisor = 1,
    },
    vs: u2,
    _rsw3: u2 = 0,
    fs: u2,
    xs: u2,
    _rsw4: u1 = 0,
    sum: bool,
    mxr: bool,
    _rsw5: u12 = 0,
    uxl: u2,
    _rsw6: u29 = 0,
    sd: bool,
});

pub const scause = Csr("scause", packed struct(u64) {
    code: packed union {
        interrupt: InterruptCode,
        exception: ExceptionCode,
    },
    interrupt: bool,

    pub const InterruptCode = enum(u63) {
        supervisor_software_interrupt = 1,
        supervisor_timer_interrupt = 5,
        supervisor_external_interrupt = 9,
        counter_overflow_interrupt = 13,
        _,
    };
    pub const ExceptionCode = enum(u63) {
        instruction_address_misaligned = 0,
        instruction_access_fault = 1,
        illegal_instruction = 2,
        breakpoint = 3,
        load_address_misaligned = 4,
        load_access_fault = 5,
        store_amo_address_misaligned = 6,
        store_amo_access_fault = 7,
        environment_call_from_u_mode = 8,
        environment_call_from_s_mode = 9,
        instruction_page_fault = 12,
        load_page_fault = 13,
        store_amo_page_fault = 15,
        software_check = 18,
        hardware_error = 19,
        _,
    };
});
pub const satp = Csr("satp", packed struct(u64) {
    ppn: u44,
    asid: u16,
    mode: enum(u4) {
        no_translation = 0,
        sv39 = 8,
        sv48 = 9,
        sv57 = 10,
        sv64 = 11,
        _,
    },
});

pub const stval = Csr("stval", u64);
pub const time = Csr("time", u64);

fn Csr(comptime name: []const u8, comptime T: type) type {
    if (@bitSizeOf(T) != @bitSizeOf(usize))
        @compileError("T must be word sized.");

    return struct {
        pub usingnamespace if (@typeInfo(T) == .Struct) T else struct {};
        pub const Field = meta.FieldEnum(T);

        pub inline fn read() T {
            var value: usize = undefined;
            asm volatile ("csrr %[value], " ++ name
                : [value] "=r" (value),
            );
            return @bitCast(value);
        }

        pub inline fn write(value: T) void {
            const v: usize = @bitCast(value);
            asm volatile ("csrw " ++ name ++ ", %[value]"
                :
                : [value] "r" (v),
            );
        }

        pub inline fn set(comptime field: Field) void {
            const field_type = meta.FieldType(T, field);
            const field_size = @bitSizeOf(field_type);
            comptime var mask = (1 << field_size) - 1;
            const field_offset = @bitOffsetOf(T, @tagName(field));
            mask <<= field_offset;
            asm volatile ("csrs " ++ name ++ ", %[mask]"
                :
                : [mask] "r" (mask),
            );
        }

        pub inline fn clear(comptime field: Field) void {
            const field_type = meta.FieldType(T, field);
            const field_size = @bitSizeOf(field_type);
            comptime var mask = (1 << field_size) - 1;
            const field_offset = @bitOffsetOf(T, @tagName(field));
            mask <<= field_offset;
            asm volatile ("csrc " ++ name ++ ", %[mask]"
                :
                : [mask] "r" (mask),
            );
        }
    };
}
