const builtin = @import("builtin");
const std = @import("std");

const MakeOptions = switch (builtin.zig_version.minor) {
    12 => *std.Progress.Node,
    13 => std.Progress.Node,
    else => @compileError("todo: add support for this zig version"),
};

pub fn build(b: *std.Build) void {
    const print_step = b.allocator.create(std.Build.Step) catch @panic("OOM");
    print_step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "print-zig-version",
        .owner = b,
        .makeFn = struct {
            fn make(step: *std.Build.Step, _: MakeOptions) anyerror!void {
                _ = step;
                try std.debug.print("{f}\n", .{builtin.zig_version});
            }
        }.make,
    });
    b.default_step = print_step;
}
