const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const libt = @import("libt");
const WaitReason = libt.syscall.WaitReason;
const Client = @This();

pub const Directory = @import("Client/Directory.zig");
pub const File = @import("Client/File.zig");

kind: Kind,
prev: ?*Client = null,
next: ?*Client = null,

pub const Kind = union(enum) {
    directory: Directory,
    file: File,
};

pub const Request = union(enum) {
    directory: Directory.Request,
    file: File.Request,
};

pub const Response = union(enum) {
    directory: Directory.Response,
    file: File.Response,
};

pub fn hasRequest(self: Client, request_out: *Request, wait_reason: ?*WaitReason) bool {
    return switch (self.kind) {
        .directory => self.kind.directory.hasRequest(request_out, wait_reason),
        .file => self.kind.file.hasRequest(request_out, wait_reason),
    };
}

pub fn handleRequest(self: *Client, request: Request, allocator: Allocator) void {
    switch (self.kind) {
        .directory => self.kind.directory.handleRequest(request.directory, allocator),
        .file => self.kind.file.handleRequest(request.file, allocator),
    }
}
