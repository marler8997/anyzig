pub fn anyzigDir(arena: std.mem.Allocator, environ: std.process.Environ) error{Reported}![:0]const u8 {
    return appDataDir(arena, environ, "anyzig") orelse {
        switch (builtin.os.tag) {
            .windows => std.log.err(
                "can't find anyzig's data directory, LOCALAPPDATA {s}",
                .{unusableEnv(environ, "LOCALAPPDATA")},
            ),
            .macos => std.log.err(
                "can't find anyzig's data directory, HOME {s}",
                .{unusableEnv(environ, "HOME")},
            ),
            else => std.log.err(
                "can't find anyzig's data directory, XDG_DATA_HOME {s} and HOME {s}",
                .{ unusableEnv(environ, "XDG_DATA_HOME"), unusableEnv(environ, "HOME") },
            ),
        }
        return error.Reported;
    };
}

/// same as zig 0.14's introspect.resolveGlobalCacheDir, where older versions of anyzig installed compilers
pub fn legacyGlobalCacheDir(arena: std.mem.Allocator, environ: std.process.Environ) ?[]const u8 {
    if (getPathEnv(arena, environ, "ZIG_GLOBAL_CACHE_DIR")) |dir| return dir;
    if (builtin.os.tag != .windows) {
        if (getPathEnv(arena, environ, "XDG_CACHE_HOME")) |xdg| return Dir.path.join(arena, &.{ xdg, "zig" }) catch |e| oom(e);
        if (getPathEnv(arena, environ, "HOME")) |home| return Dir.path.join(arena, &.{ home, ".cache", "zig" }) catch |e| oom(e);
    }
    return appDataDir(arena, environ, "zig");
}

fn appDataDir(arena: std.mem.Allocator, environ: std.process.Environ, comptime app_name: []const u8) ?[:0]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const local_app_data = getPathEnv(arena, environ, "LOCALAPPDATA") orelse return null;
            return Dir.path.joinZ(arena, &.{ local_app_data, app_name }) catch |e| oom(e);
        },
        .macos => {
            const home = getPathEnv(arena, environ, "HOME") orelse return null;
            return Dir.path.joinZ(arena, &.{ home, "Library", "Application Support", app_name }) catch |e| oom(e);
        },
        else => {
            if (getPathEnv(arena, environ, "XDG_DATA_HOME")) |xdg| return Dir.path.joinZ(arena, &.{ xdg, app_name }) catch |e| oom(e);
            const home = getPathEnv(arena, environ, "HOME") orelse return null;
            return Dir.path.joinZ(arena, &.{ home, ".local", "share", app_name }) catch |e| oom(e);
        },
    }
}

fn getPathEnv(arena: std.mem.Allocator, environ: std.process.Environ, comptime name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const value_w = environ.getWindows(comptime std.unicode.wtf8ToWtf16LeStringLiteral(name)) orelse return null;
        if (value_w.len == 0) return null;
        return std.unicode.wtf16LeToWtf8Alloc(arena, value_w) catch |e| oom(e);
    }
    const value = environ.getPosix(name) orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn unusableEnv(environ: std.process.Environ, comptime name: []const u8) []const u8 {
    return if (environ.containsConstant(name)) "is empty" else "isn't set";
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const builtin = @import("builtin");
const std = @import("std");
const Dir = std.Io.Dir;
