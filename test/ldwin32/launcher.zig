//! launcher EXE ARGS...
//!
//! Execs EXE with ARGS (EXE becomes argv[0]). Imports the same DLLs as anyzig, which
//! load ucrtbase.dll and msvcrt.dll into the process before the exec, so tests see
//! the C runtime state anyzig's targets will see. Built both multi-threaded and
//! single-threaded (like anyzig), which have different TLS setups.
//!
//! LDWIN32_TEST_HOOK breaks an assumption before the exec, to test it's detected:
//!   thread       leave a thread running
//!   ucrt-argv    make ucrtbase.dll parse argv
//!   msvcrt-argv  make msvcrt.dll parse argv
//!   env          change the environment after msvcrt.dll captured it
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const ldwin32 = @import("ldwin32");

pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub fn main() !u8 {
    std.mem.doNotOptimizeAway(&windows.crypt32.CertOpenSystemStoreW);
    std.mem.doNotOptimizeAway(&windows.advapi32.RegOpenKeyExW);
    std.mem.doNotOptimizeAway(&windows.ws2_32.accept);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) {
        std.log.err("usage: launcher EXE ARGS...", .{});
        return 0xff;
    }

    if (std.process.getenvW(L("LDWIN32_TEST_HOOK"))) |hook| {
        if (std.mem.eql(u16, hook, L("thread"))) {
            if (builtin.single_threaded) @panic("the thread hook needs a multi-threaded launcher");
            (try std.Thread.spawn(.{}, sleepForever, .{})).detach();
        } else if (std.mem.eql(u16, hook, L("ucrt-argv"))) {
            const configure: *const fn (c_int) callconv(.c) c_int = @ptrCast(try crtExport(L("ucrtbase.dll"), "_configure_narrow_argv"));
            if (configure(1) != 0) @panic("_configure_narrow_argv failed");
        } else if (std.mem.eql(u16, hook, L("msvcrt-argv"))) {
            const getmainargs: *const fn (*c_int, *[*][*:0]u8, *[*][*:0]u8, c_int, *c_int) callconv(.c) c_int =
                @ptrCast(try crtExport(L("msvcrt.dll"), "__getmainargs"));
            var argc: c_int = undefined;
            var argv: [*][*:0]u8 = undefined;
            var envp: [*][*:0]u8 = undefined;
            var new_mode: c_int = 0;
            if (getmainargs(&argc, &argv, &envp, 0, &new_mode) != 0) @panic("__getmainargs failed");
        } else if (std.mem.eql(u16, hook, L("env"))) {
            if (SetEnvironmentVariableW(L("LDWIN32_TEST_ADDED"), L("1")) == 0) @panic("SetEnvironmentVariableW failed");
        } else std.debug.panic("unknown LDWIN32_TEST_HOOK '{}'", .{std.unicode.fmtUtf16Le(hook)});
    }

    const exe = try std.unicode.wtf8ToWtf16LeAllocZ(arena, args[1]);
    ldwin32.exec(exe, .{ .start = 0, .count = 1 }) catch return 0xff;
}

fn sleepForever() void {
    while (true) std.time.sleep(std.time.ns_per_hour);
}

fn crtExport(dll: [:0]const u16, name: [:0]const u8) !*const anyopaque {
    const module = windows.kernel32.GetModuleHandleW(dll) orelse {
        std.log.err("{} isn't loaded", .{std.unicode.fmtUtf16Le(dll)});
        return error.CrtNotLoaded;
    };
    return windows.kernel32.GetProcAddress(module, name) orelse {
        std.log.err("{} has no export '{s}'", .{ std.unicode.fmtUtf16Le(dll), name });
        return error.CrtExportMissing;
    };
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) windows.BOOL;
