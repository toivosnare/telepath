pub const Header = extern struct {
    magic: [4]u8 = MAGIC,
    region_amount: u32,
    entry_point: u64,

    pub const MAGIC = [4]u8{ 'T', 'I', 'X', 0 };
};

pub const RegionHeader = packed struct {
    offset: u64,
    load_address: u64,
    size: u64,
    executable: bool,
    writable: bool,
    readable: bool,
    _padding1: u61 = 0,
};
