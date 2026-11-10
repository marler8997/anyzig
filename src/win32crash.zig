//! Windows crash reporting for panics, unhandled exceptions and errors returned from main.
//! When std can read the exe's PDB (beside it, as in the anyzig release archive), reports are
//! std's, with function names and source lines. Without it, the trace is wintrace's, each
//! frame as `module+0xoffset`, which `wintrace-symbolize` resolves later given the PDB.

/// Stack reserved for reporting a stack overflow, on top of what Windows leaves by default:
/// about 8 KiB at the unhandled exception filter on x86_64, where wintrace alone needs 4 to
/// 8 KiB. If the report needs more than is left, the second overflow ends the process with
/// no report. The test below fails if the report uses more than half of it.
pub const stack_guarantee = 32 * 1024;

const global = struct {
    /// A panic while writing a panic's report only aborts.
    var panicking = false;
    /// A fault while writing an exception's report leaves it to Windows, instead of
    /// reporting the new fault until the stack runs out.
    var reporting_exception = false;
};

/// Whether std can symbolize this exe, i.e. it found the exe's PDB.
fn haveSymbols() bool {
    const di = std.debug.getSelfDebugInfo() catch return false;
    var arena: std.heap.ArenaAllocator = .init(std.debug.getDebugInfoAllocator());
    defer arena.deinit();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    di.getSymbols(std.Options.debug_io, arena.allocator(), arena.allocator(), @intFromPtr(&haveSymbols), false, &symbols) catch return false;
    return symbols.items.len > 0 and symbols.items[0].name != null;
}

/// For `std.debug.FullPanic`.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    const first_address = first_trace_addr orelse @returnAddress();
    if (!global.panicking) {
        global.panicking = true;
        if (haveSymbols()) std.debug.defaultPanic(msg, first_address);
        var buf: [256]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        writePanic(&stderr.file_writer.interface, msg, first_address) catch {};
    }
    std.process.abort();
}

fn writePanic(w: *std.Io.Writer, msg: []const u8, first_address: usize) error{WriteFailed}!void {
    try w.print("anyzig panic: {s}\n", .{msg});
    if (@errorReturnTrace()) |trace| if (trace.index > 0) {
        try w.writeAll("error return context:\n");
        try writeErrorReturnTrace(w, trace);
        try w.writeAll("stack trace:\n");
    };
    // before the trace, which could fault
    try w.flush();
    try wintrace.writeCurrentStackTrace(w, first_address);
    try w.flush();
}

/// Reports an error returned from main as std's start code would, then exits.
pub fn exitError(err: anyerror, trace: ?*std.builtin.StackTrace) noreturn {
    std.log.err("{t}", .{err});
    if (trace) |t| if (haveSymbols()) std.debug.dumpErrorReturnTrace(t) else {
        var buf: [256]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        const w = &stderr.file_writer.interface;
        write: {
            writeErrorReturnTrace(w, t) catch break :write;
            w.flush() catch break :write;
        }
    };
    std.process.exit(1);
}

fn writeErrorReturnTrace(w: *std.Io.Writer, trace: *const std.builtin.StackTrace) error{WriteFailed}!void {
    const count = @min(trace.index, trace.instruction_addresses.len);
    try wintrace.writeAddresses(w, trace.instruction_addresses[0..count], .{ .truncated = trace.index > count });
}

pub fn unhandledExceptionFilter(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    // std.process.abort's, after a panic in a Debug build under a debugger
    if (info.ExceptionRecord.ExceptionCode == exception_breakpoint) return exception_continue_search;
    if (global.reporting_exception) return exception_continue_search;
    global.reporting_exception = true;
    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    // std's symbolizer needs more stack than an overflow leaves
    const symbolize = info.ExceptionRecord.ExceptionCode != exception_stack_overflow and haveSymbols();
    writeExceptionReport(stderr.terminal(), info, symbolize) catch {};
    return exception_execute_handler;
}

fn writeExceptionReport(t: std.Io.Terminal, info: *windows.EXCEPTION_POINTERS, symbolize: bool) error{WriteFailed}!void {
    const w = t.writer;
    const record = info.ExceptionRecord;
    try w.print("anyzig: unhandled exception 0x{X:0>8}", .{record.ExceptionCode});
    switch (record.ExceptionCode) {
        windows.EXCEPTION_ACCESS_VIOLATION => if (record.NumberParameters >= 2) {
            const access = switch (record.ExceptionInformation[0]) {
                0 => "reading",
                1 => "writing",
                8 => "executing",
                else => "accessing",
            };
            try w.print(" (access violation {s} 0x{x})", .{ access, record.ExceptionInformation[1] });
        },
        windows.EXCEPTION_ILLEGAL_INSTRUCTION => try w.writeAll(" (illegal instruction)"),
        exception_stack_overflow => try w.writeAll(" (stack overflow)"),
        exception_int_divide_by_zero => try w.writeAll(" (integer divide by zero)"),
        else => {},
    }
    try w.writeAll(" at ");
    try wintrace.writeAddress(w, @intFromPtr(record.ExceptionAddress));
    try w.writeAll("\n");
    // before the trace, which could fault
    try w.flush();
    if (symbolize) try std.debug.writeCurrentStackTrace(.{
        .context = &std.debug.cpu_context.fromWindowsContext(info.ContextRecord),
        .allow_unsafe_unwind = true,
    }, t) else try wintrace.writeStackTrace(w, info.ContextRecord);
    try w.flush();
}

test "a stack overflow's report uses at most half the stack guarantee" {
    const t = struct {
        var buf: [16384]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var result: error{WriteFailed}!void = undefined;
        var used: usize = 0;
        threadlocal var overflowing = false;
        fn thread(_: ?*anyopaque) callconv(.winapi) u32 {
            var guarantee: u32 = stack_guarantee;
            if (SetThreadStackGuarantee(&guarantee) == 0) return 2;
            overflowing = true;
            std.mem.doNotOptimizeAway(recurse(0));
            return 1;
        }
        /// Writes unhandledExceptionFilter's report into `w` on the overflowed stack, and
        /// measures the stack it uses, then ends the thread, which can't continue. The test
        /// runner's own handler would see an unhandled exception before a filter could, so
        /// this is a vectored handler. (And it doesn't lock stderr as the filter does: the
        /// test runner can hold that lock on the main thread.)
        fn handler(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
            if (info.ExceptionRecord.ExceptionCode != exception_stack_overflow or !overflowing) return exception_continue_search;
            // Fill the free stack, below this frame and the memset's, with a pattern; the
            // lowest byte the report changes is how deep it went.
            var marker: u8 = 0;
            const top = @intFromPtr(&marker) - 1024;
            const low = @intFromPtr(windows.teb().NtTib.StackLimit);
            const free: [*]volatile u8 = @ptrFromInt(low);
            @memset(free[0 .. top - low], 0xaa);
            result = writeExceptionReport(.{ .writer = &w, .mode = .no_color }, info, false);
            const deepest = for (low..top) |a| {
                if (free[a - low] != 0xaa) break a;
            } else top;
            used = @intFromPtr(&marker) - deepest;
            ExitThread(0);
        }
        noinline fn recurse(depth: usize) usize {
            var b: [4096]u8 = undefined;
            b[depth % b.len] = @truncate(depth);
            std.mem.doNotOptimizeAway(&b);
            return recurse(depth + 1) + b[depth % b.len];
        }
    };
    const handle = AddVectoredExceptionHandler(1, &t.handler) orelse return error.TestUnexpectedResult;
    defer _ = RemoveVectoredExceptionHandler(handle);
    const thread = CreateThread(null, 1024 * 1024, &t.thread, null, stack_size_param_is_a_reservation, null) orelse return error.TestUnexpectedResult;
    defer _ = CloseHandle(thread);
    try std.testing.expectEqual(0, WaitForSingleObject(thread, std.math.maxInt(u32)));
    var exit_code: u32 = undefined;
    try std.testing.expect(GetExitCodeThread(thread, &exit_code) != 0);
    try std.testing.expectEqual(0, exit_code);
    try t.result;
    if (t.used > stack_guarantee / 2) {
        std.debug.print("the report used {d} bytes of stack, over half the guarantee of {d}\n", .{ t.used, stack_guarantee });
        return error.TestUnexpectedResult;
    }
    const report = t.w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, report, "anyzig: unhandled exception 0xC00000FD (stack overflow) at "));
    // the recursion, collapsed, and the frames below it down to the thread's start
    try std.testing.expect(std.mem.indexOf(u8, report, " (x") != null);
    try std.testing.expect(std.ascii.findIgnoreCase(report, "\n    kernel32.dll+0x") != null);
}

test "an exception's report: std's with the PDB, wintrace's without, and what was accessed" {
    // the test exe's PDB is beside it
    try std.testing.expect(haveSymbols());
    var context: windows.CONTEXT = undefined;
    windows.ntdll.RtlCaptureContext(&context);
    var record: windows.EXCEPTION_RECORD = .{
        .ExceptionCode = windows.EXCEPTION_ACCESS_VIOLATION,
        .ExceptionFlags = 0,
        .ExceptionRecord = undefined,
        .ExceptionAddress = @ptrFromInt(context.getRegs().ip),
        .NumberParameters = 2,
        .ExceptionInformation = .{ 1, 8 } ++ @as([13]usize, @splat(0)),
    };
    var info: windows.EXCEPTION_POINTERS = .{ .ExceptionRecord = &record, .ContextRecord = &context };
    for ([_]bool{ true, false }) |symbolize| {
        var buf: [16384]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeExceptionReport(.{ .writer = &w, .mode = .no_color }, &info, symbolize);
        const report = w.buffered();
        try std.testing.expect(std.mem.startsWith(u8, report, "anyzig: unhandled exception 0xC0000005 (access violation writing 0x8) at "));
        try std.testing.expectEqual(symbolize, std.mem.indexOf(u8, report, "win32crash.zig:") != null);
        try std.testing.expectEqual(!symbolize, std.mem.indexOf(u8, report, "\n    wintrace\n") != null);
    }
}

test writePanic {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePanic(&w, "boom", @returnAddress());
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "anyzig panic: boom\n    wintrace\n"));
}

const exception_continue_search = 0;
const exception_execute_handler = 1;
const exception_breakpoint = 0x80000003;
const exception_stack_overflow = 0xC00000FD;
const exception_int_divide_by_zero = 0xC0000094;
const stack_size_param_is_a_reservation = 0x10000;

pub extern "kernel32" fn SetThreadStackGuarantee(size: *u32) callconv(.winapi) i32;
extern "kernel32" fn AddVectoredExceptionHandler(
    first: u32,
    handler: *const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn RemoveVectoredExceptionHandler(handle: *anyopaque) callconv(.winapi) u32;
extern "kernel32" fn CreateThread(
    attributes: ?*anyopaque,
    stack_size: usize,
    start: *const fn (?*anyopaque) callconv(.winapi) u32,
    parameter: ?*anyopaque,
    flags: u32,
    id: ?*u32,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeThread(thread: *anyopaque, code: *u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ExitThread(code: u32) callconv(.winapi) noreturn;

const std = @import("std");
const windows = std.os.windows;
const wintrace = @import("wintrace");
