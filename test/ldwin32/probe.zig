//! Prints everything a program can observe about its own identity, command line and
//! TLS. Tests run it directly and through the launcher and require identical output.
//!
//!     probe [--exit N] ARGS...
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const options = @import("probe_options");

threadlocal var tls_value: u32 = 0x1234_5678;

pub fn main() !u8 {
    if (options.bad_api) std.mem.doNotOptimizeAway(&QueryFullProcessImageNameW);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = bw.writer();

    const args = try std.process.argsAlloc(arena);
    var exit_code: u8 = 0;
    for (args, 0..) |arg, i| {
        try out.print("arg[{}]: '{s}'\n", .{ i, arg });
        if (std.mem.eql(u8, arg, "--exit") and i + 1 < args.len) exit_code = try std.fmt.parseInt(u8, args[i + 1], 10);
    }
    try out.print("GetCommandLineW: '{}'\n", .{std.unicode.fmtUtf16Le(std.mem.span(GetCommandLineW()))});
    try out.print("GetCommandLineA: '{s}'\n", .{GetCommandLineA()});
    try out.print("selfExePath: '{s}'\n", .{try std.fs.selfExePathAlloc(arena)});
    {
        var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
        const len = windows.kernel32.GetModuleFileNameW(null, &buf, buf.len);
        if (len == 0) return error.GetModuleFileNameFailed;
        try out.print("GetModuleFileNameW(null): '{}'\n", .{std.unicode.fmtUtf16Le(buf[0..len])});
    }
    var self_module: windows.HMODULE = undefined;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, @ptrCast(&main), &self_module) == 0)
        return error.GetModuleHandleExFailed;
    {
        // (with a null module these ask the kernel, see ldwin32's "Unverifiable")
        var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
        const len = K32GetModuleFileNameExW(windows.GetCurrentProcess(), self_module, &buf, buf.len);
        if (len == 0) return error.GetModuleFileNameExFailed;
        try out.print("GetModuleFileNameExW(process, self): '{}'\n", .{std.unicode.fmtUtf16Le(buf[0..len])});
        const base_len = K32GetModuleBaseNameW(windows.GetCurrentProcess(), self_module, &buf, buf.len);
        if (base_len == 0) return error.GetModuleBaseNameFailed;
        try out.print("GetModuleBaseNameW(process, self): '{}'\n", .{std.unicode.fmtUtf16Le(buf[0..base_len])});
    }
    try out.print("GetModuleHandleW(null) is self: {}\n", .{windows.kernel32.GetModuleHandleW(null) == self_module});
    {
        var modules: [1024]windows.HMODULE = undefined;
        var needed: windows.DWORD = undefined;
        if (K32EnumProcessModules(windows.GetCurrentProcess(), &modules, @sizeOf(@TypeOf(modules)), &needed) == 0)
            return error.EnumProcessModulesFailed;
        const count = needed / @sizeOf(windows.HMODULE);
        try out.print("EnumProcessModules includes self: {}\n", .{std.mem.indexOfScalar(windows.HMODULE, modules[0..@min(count, modules.len)], self_module) != null});
    }

    try out.print("TLS on main thread: 0x{x}\n", .{tls_value});
    var thread_saw: u32 = undefined;
    (try std.Thread.spawn(.{}, threadMain, .{&thread_saw})).join();
    try out.print("TLS on new thread: 0x{x}\n", .{thread_saw});
    try out.print("TLS on main thread after: 0x{x}\n", .{tls_value});

    if (builtin.link_libc) {
        const c = struct {
            extern "c" fn __p___argc() *c_int;
            extern "c" fn __p___argv() *[*][*:0]u8;
            extern "c" fn _get_pgmptr(*[*:0]u8) c_int;
            extern "c" fn getenv([*:0]const u8) ?[*:0]u8;
        };
        const argc: usize = @intCast(c.__p___argc().*);
        for (c.__p___argv().*[0..argc], 0..) |arg, i| try out.print("C argv[{}]: '{s}'\n", .{ i, arg });
        var pgmptr: [*:0]u8 = undefined;
        if (c._get_pgmptr(&pgmptr) != 0) return error.GetPgmptrFailed;
        try out.print("C _pgmptr: '{s}'\n", .{pgmptr});
        try out.print("C getenv(PATH) matches: {}\n", .{std.mem.eql(u8, std.mem.span(c.getenv("PATH") orelse return error.NoPath), try std.process.getEnvVarOwned(arena, "PATH"))});
    }
    try bw.flush();
    return exit_code;
}

fn threadMain(saw: *u32) void {
    saw.* = tls_value;
    tls_value = 7;
}

const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x2;
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x4;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]u8;
extern "kernel32" fn GetModuleHandleExW(flags: windows.DWORD, name: ?*const anyopaque, module: *windows.HMODULE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn K32EnumProcessModules(process: windows.HANDLE, modules: [*]windows.HMODULE, size: windows.DWORD, needed: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn K32GetModuleFileNameExW(process: windows.HANDLE, module: ?windows.HMODULE, name: [*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn K32GetModuleBaseNameW(process: windows.HANDLE, module: ?windows.HMODULE, name: [*]u16, size: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn QueryFullProcessImageNameW(process: windows.HANDLE, flags: windows.DWORD, name: [*]u16, size: *windows.DWORD) callconv(.winapi) windows.BOOL;
