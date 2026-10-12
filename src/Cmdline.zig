//! Provides a platform abstraction for accessing cmdline args efficiently.
//! Only allocates memory on Windows, uses the args vector directly on posix platforms.
const Cmdline = @This();

args: switch (builtin.os.tag) {
    .windows => []const [:0]const u8,
    else => std.process.Args,
},

pub fn init(args: std.process.Args, arena: std.mem.Allocator) !Cmdline {
    return .{
        .args = if (builtin.os.tag == .windows) try args.toSlice(arena) else args,
    };
}

pub fn len(self: Cmdline) usize {
    return switch (builtin.os.tag) {
        .windows => self.args.len,
        else => self.args.vector.len,
    };
}
pub fn arg(self: Cmdline, i: usize) [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => self.args[i],
        else => std.mem.span(self.args.vector[i]),
    };
}

const builtin = @import("builtin");
const std = @import("std");
