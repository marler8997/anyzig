//! Provides a platform abstraction for accessing cmdline args efficiently.
//! Only allocates memory on Windows, uses std.os.argv on posix platforms.
const Cmdline = @This();

win32_slice: switch (builtin.os.tag) {
    .windows => [][:0]u8,
    else => void,
},

pub fn alloc(allocator: std.mem.Allocator) !Cmdline {
    return .{
        .win32_slice = if (builtin.os.tag == .windows) try std.process.argsAlloc(allocator) else {},
    };
}

pub fn free(self: Cmdline, allocator: std.mem.Allocator) void {
    if (builtin.os.tag == .windows) {
        allocator.free(self.win32_slice);
    }
}

pub fn len(self: Cmdline) usize {
    return switch (builtin.os.tag) {
        .windows => self.win32_slice.len,
        else => std.os.argv.len,
    };
}
pub fn arg(self: Cmdline, i: usize) [:0]u8 {
    return switch (builtin.os.tag) {
        .windows => self.win32_slice[i],
        else => std.mem.span(std.os.argv[i]),
    };
}

pub const Optional = switch (builtin.os.tag) {
    .windows => ?Cmdline,
    else => void,
};
pub const optional: Optional = switch (builtin.os.tag) {
    .windows => null,
    else => {},
};

const builtin = @import("builtin");
const std = @import("std");
