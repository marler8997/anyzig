//! An `execve` for Windows: replaces the current program with another exe, in the
//! same process, without creating a new one.
//!
//! The exe is loaded with LoadLibraryExW, which makes ntdll's loader map it (lazily,
//! shared with the file cache), apply relocations and register its unwind data. We do
//! what the loader skips for an exe loaded as a library (bind imports, TLS, see
//! "TLS" below), make the PEB describe the new exe, edit the command line and jump
//! to its entry point.
//!
//! This only works for programs that satisfy a set of assumptions. Every assumption
//! is either checked at compile time or verified at runtime before anything is
//! modified, in which case `exec` logs the reason and returns error.ExecFailed so the
//! caller can fall back to CreateProcess. What can't be verified is listed under
//! "Unverifiable" below and must be covered by testing the programs you exec.
//!
//! Compile time (the launcher, i.e. the program calling exec):
//!   - x86_64 Windows (other architectures are untested, see `supported`)
//!   - doesn't link libc: the target would inherit its C runtime state
//!   - std's segfault handler is disabled: it would stay registered and catch the
//!     target's crashes before the target's own handler
//! Runtime, launcher:
//!   - no other threads, except the idle thread pool workers ntdll creates
//!   - no application manifest (it decides process-wide settings for the target)
//!   - no CET shadow stacks
//!   - GetCommandLineW is the PEB's command line buffer and GetCommandLineA holds
//!     its ANSI conversion, so editing both in place is all it takes
//! Runtime, target:
//!   - a native-architecture PE32+ exe (not a DLL) with relocations, the launcher's
//!     subsystem, no manifest and no .NET header
//!   - doesn't import APIs that report the process image from the kernel (e.g.
//!     QueryFullProcessImageNameW); they would report the launcher
//!   - its TLS template fits in the space reserved in the launcher's; the launcher's
//!     TLS callback list includes ours; every thread except the loader's workers
//!     has a TLS block at the launcher's index
//!   - every C runtime DLL in the process (ucrtbase, msvcrt) points at the command
//!     line buffers we edit, hasn't parsed argv yet, and has an environment that
//!     matches the process environment
//!   - after updating the PEB, GetModuleHandleW(null) and GetModuleFileNameW(null)
//!     resolve to the target
//!   - the edited command line parses into the original arguments minus the removed
//!     ones (verified with std's parser, which follows CommandLineToArgvW)
//! Unverifiable (cover with tests):
//!   - the target doesn't look up kernel image APIs at runtime (GetProcAddress), or
//!     call GetModuleFileNameExW/GetModuleBaseNameW with a null module (which also
//!     ask the kernel, but are used with explicit modules by std's stack traces)
//!   - the target doesn't assume the first module in the loader's list is itself
//!   - the target doesn't need THREAD_ATTACH TLS callbacks for threads that existed
//!     before the exec (ntdll's idle workers)
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const log = std.log.scoped(.ldwin32);

/// Whether exec is implemented (and tested) for the target being compiled.
pub const supported = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;

/// Arguments to remove from the command line, as indices into argv (argv[0] is 0).
pub const RemoveArgs = struct { start: usize, count: usize };

pub const ExecError = error{ExecFailed};

/// Replaces the current program with `exe_path` (absolute). Removes `remove_args`
/// from the command line the new program sees. Only returns on failure, after
/// logging why; by then the process hasn't been modified, except that the exe and
/// the DLLs it imports may have been loaded.
pub fn exec(exe_path: [:0]const u16, remove_args: RemoveArgs) ExecError {
    comptime {
        if (!supported) @compileError("ldwin32.exec is not supported on " ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag));
        if (builtin.link_libc) @compileError("ldwin32.exec: the launcher must not link libc, the exec'd program would inherit its C runtime state");
        if (std.options.enable_segfault_handler) @compileError(
            "ldwin32.exec: set std_options.enable_segfault_handler = false in the launcher, " ++
                "its handler would stay registered and catch the exec'd program's crashes",
        );
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const target = prepare(arena_state.allocator(), exe_path, remove_args) catch |err| switch (err) {
        error.ExecFailed => return error.ExecFailed,
        error.OutOfMemory => {
            log.err("out of memory", .{});
            return error.ExecFailed;
        },
    };
    commit(target);
}

const Target = struct {
    module: windows.HMODULE,
    main_entry: *LdrEntry,
    target_entry: *const LdrEntry,
    exe_path: [:0]const u16,
    entry: *const fn () callconv(.winapi) u32,
    tls: ?TlsPlan,
    cmd_w: []u16,
    new_cmd_w: []const u16,
    cmd_a: []u8,
    new_cmd_a: []const u8,
};

fn prepare(arena: std.mem.Allocator, exe_path: [:0]const u16, remove_args: RemoveArgs) error{ ExecFailed, OutOfMemory }!Target {
    const exe = std.unicode.fmtUtf16Le(exe_path);
    if (!std.fs.path.isAbsoluteWindowsWTF16(exe_path)) return fail("exe path '{}' is not absolute", .{exe});

    // launcher
    const self_module = windows.peb().ImageBaseAddress;
    const self_nt = try ntHeaders(@as([*]const u8, @ptrCast(self_module))[0..4096], "launcher");
    if (try hasManifest(self_module)) return fail("the launcher has an application manifest, it would apply to '{}'", .{exe});
    try checkThreads();
    try checkShadowStack();
    const cmd = try planCommandLine(arena, remove_args);

    // Check the headers before loading anything (loading a DLL would run its DllMain).
    {
        var buf: [4096]u8 = undefined;
        const file = windows.kernel32.CreateFileW(
            exe_path,
            windows.GENERIC_READ,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (file == windows.INVALID_HANDLE_VALUE) return fail("open '{}' failed, error={}", .{ exe, @intFromEnum(windows.GetLastError()) });
        defer windows.CloseHandle(file);
        const len = windows.ReadFile(file, &buf, null) catch |err| return fail("read '{}' failed: {s}", .{ exe, @errorName(err) });
        const nt = try ntHeaders(buf[0..len], @as([]const u16, exe_path));
        const opt = &nt.OptionalHeader;
        if (nt.FileHeader.Characteristics & IMAGE_FILE_DLL != 0) return fail("'{}' is a DLL", .{exe});
        if (nt.FileHeader.Characteristics & IMAGE_FILE_EXECUTABLE_IMAGE == 0) return fail("'{}' is not marked executable", .{exe});
        if (opt.DllCharacteristics & IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE == 0 or
            nt.FileHeader.Characteristics & IMAGE_FILE_RELOCS_STRIPPED != 0 or
            dataDir(opt, .BASERELOC).Size == 0)
            return fail("'{}' is not relocatable (no DYNAMIC_BASE or no relocations)", .{exe});
        if (opt.Subsystem != self_nt.OptionalHeader.Subsystem) return fail(
            "'{}' has subsystem {} but the launcher has {}, the process was set up for the launcher's",
            .{ exe, opt.Subsystem, self_nt.OptionalHeader.Subsystem },
        );
        if (dataDir(opt, .CLR).Size != 0) return fail("'{}' is a .NET assembly", .{exe});
        if (dataDir(opt, .DELAY_IMPORT).Size != 0) return fail("'{}' has delay-load imports, which aren't checked", .{exe});
    }

    const module = windows.kernel32.LoadLibraryExW(exe_path, null, 0) orelse
        return fail("LoadLibraryExW '{}' failed, error={}", .{ exe, @intFromEnum(windows.GetLastError()) });
    errdefer _ = windows.kernel32.FreeLibrary(module);
    const base: [*]u8 = @ptrCast(module);
    const opt = &(try ntHeaders(base[0..4096], @as([]const u16, exe_path))).OptionalHeader;

    if (try hasManifest(module)) return fail("'{}' has an application manifest, which only applies when it starts a process", .{exe});
    try checkImports(base, opt, exe_path);
    try bindImports(base, opt, exe_path);

    const tls = try planTls(self_module, base, opt, exe_path);
    try checkCrts(arena);

    // GetModuleFileNameW(null) reads the loader's entry for the main exe (the first
    // module loaded), not PEB.ImageBaseAddress, so commit renames that entry.
    const entries = &windows.peb().Ldr.InMemoryOrderModuleList;
    const main_entry: *LdrEntry = @fieldParentPtr("InMemoryOrderLinks", entries.Flink);
    if (main_entry.DllBase != @as(*anyopaque, @ptrCast(self_module))) return fail("the first module in the loader's list isn't the launcher", .{});
    const target_entry: *LdrEntry = blk: {
        var it = entries.Flink;
        while (it != entries) : (it = it.Flink) {
            const entry: *LdrEntry = @fieldParentPtr("InMemoryOrderLinks", it);
            if (entry.DllBase == @as(*anyopaque, @ptrCast(module))) break :blk entry;
        }
        return fail("'{}' isn't in the loader's module list", .{exe});
    };

    return .{
        .module = module,
        .main_entry = main_entry,
        .target_entry = target_entry,
        .exe_path = exe_path,
        .entry = @ptrCast(base + opt.AddressOfEntryPoint),
        .tls = tls,
        .cmd_w = cmd.cmd_w,
        .new_cmd_w = cmd.new_cmd_w,
        .cmd_a = cmd.cmd_a,
        .new_cmd_a = cmd.new_cmd_a,
    };
}

fn commit(target: Target) noreturn {
    const peb = windows.peb();
    peb.ImageBaseAddress = target.module;
    peb.ProcessParameters.ImagePathName = .{
        .Buffer = @constCast(target.exe_path.ptr),
        .Length = @intCast(target.exe_path.len * 2),
        .MaximumLength = @intCast(target.exe_path.len * 2 + 2),
    };
    target.main_entry.FullDllName = target.target_entry.FullDllName;
    target.main_entry.BaseDllName = target.target_entry.BaseDllName;
    // From here on the process belongs to the target, failures are fatal.
    if (windows.kernel32.GetModuleHandleW(null) != target.module) fatal("GetModuleHandleW(null) doesn't resolve to the exec'd module", .{});
    {
        var buf: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const len = windows.kernel32.GetModuleFileNameW(null, &buf, buf.len);
        if (len == 0 or len == buf.len) fatal("GetModuleFileNameW(null) failed, error={}", .{@intFromEnum(windows.GetLastError())});
        if (!std.mem.eql(u16, buf[0..len], target.exe_path)) fatal(
            "GetModuleFileNameW(null) returned '{}' instead of '{}'",
            .{ std.unicode.fmtUtf16Le(buf[0..len]), std.unicode.fmtUtf16Le(target.exe_path) },
        );
    }

    // shrink both command lines in place, keeping their buffers (see planCommandLine)
    const cmdline = &peb.ProcessParameters.CommandLine;
    // (the slices end at the existing terminators, so they only need a new one if shorter)
    std.mem.copyForwards(u16, target.cmd_w, target.new_cmd_w);
    if (target.new_cmd_w.len < target.cmd_w.len) target.cmd_w[target.new_cmd_w.len] = 0;
    cmdline.Length = @intCast(target.new_cmd_w.len * 2);
    std.mem.copyForwards(u8, target.cmd_a, target.new_cmd_a);
    if (target.new_cmd_a.len < target.cmd_a.len) target.cmd_a[target.new_cmd_a.len] = 0;

    if (target.tls) |plan| execTls(plan, target.module);
    // like RtlUserThreadStart, exit with the entry point's result if it returns
    windows.kernel32.ExitProcess(target.entry());
}

/// The edits to make to both command lines, computed and verified up front.
const CommandLinePlan = struct {
    cmd_w: []u16,
    new_cmd_w: []const u16,
    cmd_a: []u8,
    new_cmd_a: []const u8,
};

fn planCommandLine(arena: std.mem.Allocator, remove_args: RemoveArgs) error{ ExecFailed, OutOfMemory }!CommandLinePlan {
    const cmdline = &windows.peb().ProcessParameters.CommandLine;
    const cmd_w = cmdline.Buffer.?[0 .. cmdline.Length / 2];
    // kernelbase caches the PEB's string (so GetCommandLineW returns the PEB buffer)
    // and an ANSI conversion of it (GetCommandLineA), which is where msvcrt and ucrt
    // get argv. Editing both buffers in place updates every view of the command line.
    if (GetCommandLineW() != cmd_w.ptr) return fail("GetCommandLineW() isn't the PEB command line buffer", .{});
    const cmd_a = std.mem.span(GetCommandLineA());
    const cmd_w_as_ansi = try toAnsi(arena, cmd_w);
    if (!std.mem.eql(u8, cmd_a, cmd_w_as_ansi))
        return fail("GetCommandLineA() '{s}' isn't the ANSI conversion of the command line '{s}'", .{ cmd_a, cmd_w_as_ansi });

    const new_cmd_w = removeArgs(arena, cmd_w, remove_args) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidRemoveArgs => return fail("can't remove args {}..{} from command line '{}'", .{
            remove_args.start, remove_args.start + remove_args.count, std.unicode.fmtUtf16Le(cmd_w),
        }),
        error.ArgsChanged => return fail(
            "removing args {}..{} from command line '{}' would change how the remaining args parse",
            .{ remove_args.start, remove_args.start + remove_args.count, std.unicode.fmtUtf16Le(cmd_w) },
        ),
    };
    const new_cmd_a = try toAnsi(arena, new_cmd_w);
    if (new_cmd_a.len > cmd_a.len) return fail("the new ANSI command line is longer than the original", .{});
    return .{ .cmd_w = cmd_w, .new_cmd_w = new_cmd_w, .cmd_a = cmd_a, .new_cmd_a = new_cmd_a };
}

/// Returns `cmd` with the args in `remove` removed (as a slice into a new buffer),
/// and verifies with std's parser that the result parses into the same args minus
/// the removed ones. Removing argv[0] makes the next arg argv[0], which parses by
/// different rules, so that case is only allowed when the result is the same.
fn removeArgs(arena: std.mem.Allocator, cmd: []const u16, remove: RemoveArgs) error{ OutOfMemory, InvalidRemoveArgs, ArgsChanged }![]const u16 {
    var starts: std.ArrayListUnmanaged(usize) = .{};
    var ends: std.ArrayListUnmanaged(usize) = .{};
    {
        var it = try std.process.ArgIteratorWindows.init(arena, cmd);
        var pos: usize = 0;
        while (true) {
            while (pos < cmd.len and (cmd[pos] == ' ' or cmd[pos] == '\t')) pos += 1;
            if (pos == cmd.len and starts.items.len > 0) break;
            std.debug.assert(it.index <= pos);
            it.index = pos;
            if (!it.skip()) break;
            // skipping argv[0] also consumes the whitespace after it
            var end = it.index;
            while (end > pos and (cmd[end - 1] == ' ' or cmd[end - 1] == '\t')) end -= 1;
            try starts.append(arena, pos);
            try ends.append(arena, end);
            pos = it.index;
        }
    }
    const end = std.math.add(usize, remove.start, remove.count) catch return error.InvalidRemoveArgs;
    if (end > starts.items.len) return error.InvalidRemoveArgs;
    if (remove.count == starts.items.len) return error.InvalidRemoveArgs; // must keep an argv[0]
    if (remove.count == 0) return cmd;

    const new_cmd: []const u16 = if (end < starts.items.len)
        try std.mem.concat(arena, u16, &.{ cmd[0..starts.items[remove.start]], cmd[starts.items[end]..] })
    else
        try arena.dupe(u16, cmd[0..ends.items[remove.start - 1]]);

    var old_it = try std.process.ArgIteratorWindows.init(arena, cmd);
    var new_it = try std.process.ArgIteratorWindows.init(arena, new_cmd);
    var i: usize = 0;
    while (old_it.next()) |old_arg| : (i += 1) {
        if (i >= remove.start and i < end) continue;
        const new_arg = new_it.next() orelse return error.ArgsChanged;
        if (!std.mem.eql(u8, old_arg, new_arg)) return error.ArgsChanged;
    }
    if (new_it.next() != null) return error.ArgsChanged;
    return new_cmd;
}

fn toAnsi(arena: std.mem.Allocator, s: []const u16) error{ ExecFailed, OutOfMemory }![]u8 {
    if (s.len == 0) return arena.alloc(u8, 0);
    const len = WideCharToMultiByte(CP_ACP, 0, s.ptr, @intCast(s.len), null, 0, null, null);
    if (len <= 0) return fail("WideCharToMultiByte failed, error={}", .{@intFromEnum(windows.GetLastError())});
    const buf = try arena.alloc(u8, @intCast(len));
    if (WideCharToMultiByte(CP_ACP, 0, s.ptr, @intCast(s.len), buf.ptr, len, null, null) != len)
        return fail("WideCharToMultiByte failed, error={}", .{@intFromEnum(windows.GetLastError())});
    return buf;
}

/// Fails if any thread other than this one is running code that isn't ntdll's (the
/// loader starts thread pool workers to load DLLs in parallel).
fn checkThreads() error{ExecFailed}!void {
    const ntdll = windows.kernel32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse
        return fail("GetModuleHandleW(ntdll) failed", .{});
    const ntdll_start = @intFromPtr(ntdll);
    const ntdll_end = ntdll_start + (try ntHeaders(@as([*]const u8, @ptrCast(ntdll))[0..4096], "ntdll")).OptionalHeader.SizeOfImage;
    const self_id = windows.GetCurrentThreadId();

    var threads: ThreadIterator = .{};
    defer threads.deinit();
    while (try threads.next()) |thread| {
        if (thread.id == self_id) continue;
        if (thread.start < ntdll_start or thread.start >= ntdll_end) return fail(
            "thread {} (start address 0x{x}) is running, exec would leave it running in the new program",
            .{ thread.id, thread.start },
        );
    }
}

fn checkShadowStack() error{ExecFailed}!void {
    var policy: u32 = 0;
    if (GetProcessMitigationPolicy(windows.GetCurrentProcess(), ProcessUserShadowStackPolicy, &policy, @sizeOf(u32)) == 0) {
        // older versions of Windows don't know the policy, so it can't be enabled
        if (windows.GetLastError() == .INVALID_PARAMETER) return;
        return fail("GetProcessMitigationPolicy failed, error={}", .{@intFromEnum(windows.GetLastError())});
    }
    if (policy & 1 != 0) return fail("CET shadow stacks are enabled for this process", .{});
}

fn hasManifest(module: windows.HMODULE) error{ExecFailed}!bool {
    var count: usize = 0;
    if (EnumResourceNamesW(module, RT_MANIFEST, countResource, @intCast(@intFromPtr(&count))) == 0) switch (windows.GetLastError()) {
        .RESOURCE_DATA_NOT_FOUND, .RESOURCE_TYPE_NOT_FOUND => return false,
        else => |e| return fail("EnumResourceNamesW failed, error={}", .{@intFromEnum(e)}),
    };
    return count != 0;
}
fn countResource(_: ?windows.HMODULE, _: ?[*:0]const u16, _: ?[*:0]const u16, param: isize) callconv(.winapi) windows.BOOL {
    @as(*usize, @ptrFromInt(@as(usize, @bitCast(param)))).* += 1;
    return windows.TRUE;
}

/// APIs that ask the kernel for the process image, which is still the launcher's.
/// (GetModuleFileNameEx and friends read the PEB and loader list, which we update.)
const kernel_image_apis = [_][]const u8{
    "QueryFullProcessImageNameA",  "QueryFullProcessImageNameW",
    "GetProcessImageFileNameA",    "GetProcessImageFileNameW",
    "K32GetProcessImageFileNameA", "K32GetProcessImageFileNameW",
};

fn checkImports(base: [*]u8, opt: *align(1) const ImageOptionalHeader64, exe_path: []const u16) error{ExecFailed}!void {
    var it = importIterator(base, opt);
    while (it.nextLib()) |lib| {
        var names = lib.names();
        while (names.next()) |entry| switch (entry) {
            .ordinal => {},
            .name => |name| for (kernel_image_apis) |api| {
                if (std.mem.eql(u8, name, api)) return fail(
                    "'{}' imports {s}!{s}, which would report the launcher instead of it",
                    .{ std.unicode.fmtUtf16Le(exe_path), lib.name, name },
                );
            },
        };
    }
}

/// The loader doesn't bind an exe's imports when it loads it as a library.
fn bindImports(base: [*]u8, opt: *align(1) const ImageOptionalHeader64, exe_path: []const u16) error{ExecFailed}!void {
    const iat = dataDir(opt, .IAT);
    if (iat.Size == 0) return;
    var old_protect: windows.DWORD = undefined;
    windows.VirtualProtect(base + iat.VirtualAddress, iat.Size, windows.PAGE_READWRITE, &old_protect) catch |err|
        return fail("VirtualProtect(IAT) failed: {s}", .{@errorName(err)});
    defer windows.VirtualProtect(base + iat.VirtualAddress, iat.Size, old_protect, &old_protect) catch |err|
        fatal("VirtualProtect(IAT) failed restoring protection: {s}", .{@errorName(err)});

    var it = importIterator(base, opt);
    while (it.nextLib()) |lib| {
        var lib_name_w: [windows.PATH_MAX_WIDE:0]u16 = undefined;
        if (lib.name.len >= lib_name_w.len) return fail("import library name too long: '{s}'", .{lib.name});
        for (lib.name, 0..) |c, i| lib_name_w[i] = c;
        lib_name_w[lib.name.len] = 0;
        const handle = windows.kernel32.LoadLibraryW(&lib_name_w) orelse
            return fail("'{}' imports '{s}' which failed to load, error={}", .{ std.unicode.fmtUtf16Le(exe_path), lib.name, @intFromEnum(windows.GetLastError()) });

        if (lib.first_thunk < iat.VirtualAddress or lib.first_thunk >= iat.VirtualAddress + iat.Size)
            return fail("import thunks for '{s}' are outside the IAT", .{lib.name});
        const slots: [*]align(1) u64 = @ptrCast(base + lib.first_thunk);
        var names = lib.names();
        var i: usize = 0;
        while (names.next()) |entry| : (i += 1) {
            const proc: [*:0]const u8 = switch (entry) {
                .ordinal => |o| @ptrFromInt(o),
                .name => |n| n.ptr,
            };
            const addr = windows.kernel32.GetProcAddress(handle, proc) orelse return switch (entry) {
                .ordinal => |o| fail("'{s}' has no export with ordinal {}", .{ lib.name, o }),
                .name => |n| fail("'{s}' has no export '{s}'", .{ lib.name, n }),
            };
            slots[i] = @intFromPtr(addr);
        }
    }
}

// TLS
//
// The loader doesn't set up TLS for an exe loaded as a library (its _tls_index is
// never assigned), and has no API to register it. Instead the target borrows the
// launcher's TLS, which the loader manages for every thread: the launcher's template
// is overwritten with the target's (the loader copies it into each new thread's
// block), the target uses the launcher's TLS index, and the existing threads' blocks
// are re-initialized. The launcher's template must be big enough, so this module
// reserves room in it. The loader calls the launcher's TLS callbacks (thread attach
// and detach, process detach), so this module adds one that forwards to the target's.

const TlsCallback = *const fn (?*anyopaque, windows.DWORD, ?*anyopaque) callconv(.winapi) void;
const TlsDirectory = extern struct {
    StartAddressOfRawData: u64,
    EndAddressOfRawData: u64,
    AddressOfIndex: u64,
    AddressOfCallBacks: u64,
    SizeOfZeroFill: u32,
    Characteristics: u32,
};

/// Room for the target's TLS template in the launcher's (zig 0.15's is 9.9 KiB).
/// Placed in the template by section (between _tls_start in ".tls" and _tls_end in
/// ".tls$ZZZ") rather than declared threadlocal, which single-threaded builds turn
/// into an ordinary global.
const tls_reserve_size = 32 * 1024;
var tls_reserve: [tls_reserve_size]u8 linksection(".tls$B") = @splat(0xaa);

/// In the launcher's TLS callback list (the TLS directory takes the callbacks
/// between .CRT$XLA and .CRT$XLZ).
var ldwin32_tls_callback: ?TlsCallback linksection(".CRT$XLB") = &forwardTlsCallback;

comptime {
    if (supported) {
        @export(&ldwin32_tls_callback, .{ .name = "ldwin32_tls_callback" });
        // std only provides the TLS directory for multi-threaded builds
        if (builtin.single_threaded) _ = single_threaded_tls;
    }
}

/// The TLS directory std provides for multi-threaded builds (std/os/windows/tls.zig),
/// which this module needs even when single-threaded.
const single_threaded_tls = struct {
    export var _tls_index: u32 = windows.TLS_OUT_OF_INDEXES;
    export var _tls_start: ?*anyopaque linksection(".tls") = null;
    export var _tls_end: ?*anyopaque linksection(".tls$ZZZ") = null;
    export var __xl_a: windows.PIMAGE_TLS_CALLBACK linksection(".CRT$XLA") = null;
    export var __xl_z: windows.PIMAGE_TLS_CALLBACK linksection(".CRT$XLZ") = null;
    const Directory = extern struct {
        StartAddressOfRawData: *?*anyopaque,
        EndAddressOfRawData: *?*anyopaque,
        AddressOfIndex: *u32,
        AddressOfCallBacks: [*:null]windows.PIMAGE_TLS_CALLBACK,
        SizeOfZeroFill: u32,
        Characteristics: u32,
    };
    export const _tls_used linksection(".rdata$T") = Directory{
        .StartAddressOfRawData = &_tls_start,
        .EndAddressOfRawData = &_tls_end,
        .AddressOfIndex = &_tls_index,
        // the callbacks are between __xl_a and __xl_z
        .AddressOfCallBacks = @as([*:null]windows.PIMAGE_TLS_CALLBACK, @ptrCast(&__xl_a)) + 1,
        .SizeOfZeroFill = 0,
        .Characteristics = 0,
    };
};
var target_tls_callbacks: ?[*]align(1) const ?TlsCallback = null;
var target_tls_module: ?*anyopaque = null;
fn forwardTlsCallback(_: ?*anyopaque, reason: windows.DWORD, reserved: ?*anyopaque) callconv(.winapi) void {
    var cb = target_tls_callbacks orelse return;
    while (cb[0]) |f| : (cb += 1) f(target_tls_module, reason, reserved);
}

const TlsPlan = struct {
    index: u32,
    /// the launcher's template (raw data and zero fill), which we overwrite
    template: []u8,
    template_raw_len: usize,
    target_template: []const u8,
    target_index: *align(1) u32,
    target_callbacks: ?[*]align(1) const ?TlsCallback,
};

fn planTls(launcher: windows.HMODULE, target_base: [*]u8, target_opt: *align(1) const ImageOptionalHeader64, exe_path: []const u16) error{ExecFailed}!?TlsPlan {
    std.mem.doNotOptimizeAway(&tls_reserve);
    std.mem.doNotOptimizeAway(&ldwin32_tls_callback);
    const exe = std.unicode.fmtUtf16Le(exe_path);
    const target_dir = dataDir(target_opt, .TLS);
    if (target_dir.Size == 0) return null;
    const t: *align(1) const TlsDirectory = @ptrCast(target_base + target_dir.VirtualAddress);

    const launcher_base: [*]u8 = @ptrCast(launcher);
    const launcher_dir = dataDir(&(try ntHeaders(launcher_base[0..4096], "launcher")).OptionalHeader, .TLS);
    if (launcher_dir.Size == 0) return fail("the launcher has no TLS directory (ldwin32's TLS reserve should create one)", .{});
    const l: *align(1) const TlsDirectory = @ptrCast(launcher_base + launcher_dir.VirtualAddress);

    const callbacks: [*]align(1) const ?TlsCallback = @ptrFromInt(l.AddressOfCallBacks);
    for (0..std.math.maxInt(usize)) |i| {
        const cb = callbacks[i] orelse return fail("ldwin32's TLS callback isn't in the launcher's TLS callback list", .{});
        if (cb == &forwardTlsCallback) break;
    }

    const raw_len = l.EndAddressOfRawData - l.StartAddressOfRawData;
    const t_raw_len = t.EndAddressOfRawData - t.StartAddressOfRawData;
    if (t_raw_len > raw_len or t_raw_len + t.SizeOfZeroFill > raw_len + l.SizeOfZeroFill) return fail(
        "'{}' has {} + {} bytes of TLS, more than the {} + {} reserved in the launcher",
        .{ exe, t_raw_len, t.SizeOfZeroFill, raw_len, l.SizeOfZeroFill },
    );
    // (TLS alignment isn't checked: the loader allocates the blocks the same way it
    // would for the target, and ignores the alignment in Characteristics either way)
    // the zero fill isn't in the image, so only the raw data is overwritten
    if (l.SizeOfZeroFill != 0) return fail("the launcher's TLS has zero fill, which isn't supported", .{});

    var info: windows.MEMORY_BASIC_INFORMATION = undefined;
    if (windows.kernel32.VirtualQuery(@ptrFromInt(l.StartAddressOfRawData), &info, @sizeOf(@TypeOf(info))) == 0)
        return fail("VirtualQuery of the launcher's TLS template failed, error={}", .{@intFromEnum(windows.GetLastError())});
    if (info.Protect & (windows.PAGE_READWRITE | windows.PAGE_WRITECOPY) == 0 or
        @intFromPtr(info.BaseAddress) + info.RegionSize < l.EndAddressOfRawData)
        return fail("the launcher's TLS template isn't writable (protection 0x{x})", .{info.Protect});

    const index = @as(*align(1) const u32, @ptrFromInt(l.AddressOfIndex)).*;
    var threads: ThreadIterator = .{};
    defer threads.deinit();
    while (try threads.next()) |thread| {
        if (thread.isLoaderWorker()) continue;
        if (thread.tlsBlock(index) == null) return fail(
            "thread {} (start address 0x{x}, current={}) has no TLS block at the launcher's index {}",
            .{ thread.id, thread.start, thread.id == windows.GetCurrentThreadId(), index },
        );
    }

    return .{
        .index = index,
        .template = @as([*]u8, @ptrFromInt(l.StartAddressOfRawData))[0..raw_len],
        .template_raw_len = raw_len,
        .target_template = @as([*]const u8, @ptrFromInt(t.StartAddressOfRawData))[0..t_raw_len],
        .target_index = @ptrFromInt(t.AddressOfIndex),
        .target_callbacks = if (t.AddressOfCallBacks == 0) null else @ptrFromInt(t.AddressOfCallBacks),
    };
}

/// Point of no return: gives the launcher's TLS to the target.
fn execTls(plan: TlsPlan, module: windows.HMODULE) void {
    // new threads: the loader copies the template (its raw data length) into them
    @memcpy(plan.template[0..plan.target_template.len], plan.target_template);
    @memset(plan.template[plan.target_template.len..], 0);
    plan.target_index.* = plan.index;
    // existing threads
    var threads: ThreadIterator = .{};
    defer threads.deinit();
    while (threads.next() catch fatal("enumerating threads failed", .{})) |thread| {
        if (thread.isLoaderWorker()) continue;
        const block = thread.tlsBlock(plan.index) orelse fatal("thread {} has no TLS block", .{thread.id});
        @memcpy(block[0..plan.template.len], plan.template);
    }
    target_tls_module = module;
    target_tls_callbacks = plan.target_callbacks;
    forwardTlsCallback(null, DLL_PROCESS_ATTACH, null);
}

/// Iterates the threads of this process (including this one).
const ThreadIterator = struct {
    handle: ?windows.HANDLE = null,

    const Thread = struct {
        id: windows.DWORD,
        teb: *windows.TEB,
        start: usize,

        /// The loader's parallel loading workers have no TLS and only ever run
        /// loader work (mapping and binding DLLs), never program code.
        fn isLoaderWorker(t: Thread) bool {
            // TEB.SameTebFlags, bit 13 is LoaderWorker
            const same_teb_flags: *const u16 = @ptrFromInt(@intFromPtr(t.teb) + 0x17ee);
            return same_teb_flags.* & (1 << 13) != 0;
        }

        fn tlsBlock(t: Thread, index: u32) ?[*]u8 {
            // std types this as non-optional, but it's null in a thread without TLS
            const slots = @as(*const ?[*]?[*]u8, @ptrCast(&t.teb.ThreadLocalStoragePointer)).* orelse return null;
            return slots[index];
        }
    };

    fn next(it: *ThreadIterator) error{ExecFailed}!?Thread {
        var next_handle: windows.HANDLE = undefined;
        const status = NtGetNextThread(windows.GetCurrentProcess(), it.handle, THREAD_QUERY_INFORMATION, 0, 0, &next_handle);
        if (status == .NO_MORE_ENTRIES) return null;
        if (status != .SUCCESS) return fail("NtGetNextThread failed, status=0x{x}", .{@intFromEnum(status)});
        if (it.handle) |h| windows.CloseHandle(h);
        it.handle = next_handle;

        var basic: extern struct {
            ExitStatus: windows.NTSTATUS,
            TebBaseAddress: ?*windows.TEB,
            ClientId: extern struct { UniqueProcess: usize, UniqueThread: usize },
            AffinityMask: usize,
            Priority: i32,
            BasePriority: i32,
        } = undefined;
        const q = windows.ntdll.NtQueryInformationThread(next_handle, .ThreadBasicInformation, &basic, @sizeOf(@TypeOf(basic)), null);
        if (q != .SUCCESS) return fail("NtQueryInformationThread(ThreadBasicInformation) failed, status=0x{x}", .{@intFromEnum(q)});
        var start: usize = undefined;
        const q2 = windows.ntdll.NtQueryInformationThread(next_handle, .ThreadQuerySetWin32StartAddress, &start, @sizeOf(usize), null);
        if (q2 != .SUCCESS) return fail("NtQueryInformationThread(Win32StartAddress) failed, status=0x{x}", .{@intFromEnum(q2)});
        return .{
            .id = @intCast(basic.ClientId.UniqueThread),
            .teb = basic.TebBaseAddress orelse return fail("thread {} has no TEB", .{basic.ClientId.UniqueThread}),
            .start = start,
        };
    }

    fn deinit(it: *ThreadIterator) void {
        if (it.handle) |h| windows.CloseHandle(h);
    }
};

/// The C runtime DLLs keep their own view of the command line and environment. Any
/// that are loaded (whether by the launcher's dependencies or the target's imports)
/// must still be in their initial state, pointing at the buffers we edit.
fn checkCrts(arena: std.mem.Allocator) error{ ExecFailed, OutOfMemory }!void {
    for ([_][]const u8{ "ucrtbase.dll", "msvcrt.dll" }) |name| {
        var name_w: [32:0]u16 = undefined;
        for (name, 0..) |c, i| name_w[i] = c;
        name_w[name.len] = 0;
        const crt = windows.kernel32.GetModuleHandleW(&name_w) orelse continue;

        // null means it hasn't captured them yet, it will see the edited ones
        if ((try crtVar(crt, name, "_acmdln", ?[*:0]u8)).*) |acmdln| {
            if (acmdln != GetCommandLineA()) return fail("{s}'s _acmdln isn't GetCommandLineA()", .{name});
        }
        if ((try crtVar(crt, name, "_wcmdln", ?[*:0]u16)).*) |wcmdln| {
            if (wcmdln != GetCommandLineW()) return fail("{s}'s _wcmdln isn't GetCommandLineW()", .{name});
        }
        const argc = (try crtVar(crt, name, "__argc", c_int)).*;
        if (argc != 0) return fail("{s} has already parsed argv (argc={})", .{ name, argc });

        // A C runtime initializes its environment once (msvcrt when it loads, ucrt on
        // first use), after which it doesn't see SetEnvironmentVariable changes.
        if ((try crtVar(crt, name, "_wenviron", ?[*:null]?[*:0]u16)).*) |env| try checkCrtEnvironment(arena, name, u16, env);
        if ((try crtVar(crt, name, "_environ", ?[*:null]?[*:0]u8)).*) |env| try checkCrtEnvironment(arena, name, u8, env);
    }
}

/// Returns a C runtime global, through its `__p_` accessor function (ucrtbase) or
/// its data export (msvcrt).
fn crtVar(crt: windows.HMODULE, crt_name: []const u8, comptime name: [:0]const u8, comptime T: type) error{ExecFailed}!*T {
    if (windows.kernel32.GetProcAddress(crt, "__p_" ++ name)) |getter|
        return @as(*const fn () callconv(.c) *T, @ptrCast(getter))();
    const addr = windows.kernel32.GetProcAddress(crt, name) orelse
        return fail("{s} exports neither '__p_{s}' nor '{s}'", .{ crt_name, name, name });
    return @alignCast(@ptrCast(addr));
}

fn checkCrtEnvironment(arena: std.mem.Allocator, crt_name: []const u8, comptime T: type, crt_env: [*:null]?[*:0]T) error{ ExecFailed, OutOfMemory }!void {
    const block = windows.kernel32.GetEnvironmentStringsW() orelse return fail("GetEnvironmentStringsW failed", .{});
    defer _ = windows.kernel32.FreeEnvironmentStringsW(block);
    var i: usize = 0;
    var offset: usize = 0;
    while (block[offset] != 0) {
        const entry_w = std.mem.sliceTo(block[offset..], 0);
        offset += entry_w.len + 1;
        // the C runtimes leave out the per-drive current directories ("=C:=C:\...")
        if (entry_w[0] == '=') continue;
        const entry = crt_env[i] orelse return fail("{s}'s environment is missing '{}'", .{ crt_name, std.unicode.fmtUtf16Le(entry_w) });
        const expected: []const T = if (T == u16) entry_w else try toAnsi(arena, entry_w);
        if (!std.mem.eql(T, std.mem.span(entry), expected))
            return fail("{s}'s environment is out of date at '{}'", .{ crt_name, std.unicode.fmtUtf16Le(entry_w) });
        i += 1;
    }
    if (crt_env[i] != null) return fail("{s}'s environment has extra entries", .{crt_name});
}

const ImportIterator = struct {
    base: [*]u8,
    desc: ?[*]align(1) const ImportDescriptor,

    const Lib = struct {
        base: [*]u8,
        name: []const u8,
        names_rva: u32,
        first_thunk: u32,

        fn names(lib: Lib) NameIterator {
            return .{ .base = lib.base, .thunk = @ptrCast(lib.base + lib.names_rva) };
        }
    };
    const NameIterator = struct {
        base: [*]u8,
        thunk: [*]align(1) const u64,
        fn next(it: *NameIterator) ?union(enum) { ordinal: u16, name: [:0]const u8 } {
            const v = it.thunk[0];
            if (v == 0) return null;
            it.thunk += 1;
            if (v & (1 << 63) != 0) return .{ .ordinal = @truncate(v) };
            // skip IMAGE_IMPORT_BY_NAME.Hint
            return .{ .name = std.mem.span(@as([*:0]const u8, @ptrCast(it.base + @as(u32, @truncate(v)) + 2))) };
        }
    };

    fn nextLib(it: *ImportIterator) ?Lib {
        const desc = it.desc orelse return null;
        if (desc[0].Name == 0) return null;
        it.desc = desc + 1;
        return .{
            .base = it.base,
            .name = std.mem.span(@as([*:0]const u8, @ptrCast(it.base + desc[0].Name))),
            .names_rva = if (desc[0].OriginalFirstThunk != 0) desc[0].OriginalFirstThunk else desc[0].FirstThunk,
            .first_thunk = desc[0].FirstThunk,
        };
    }
};
fn importIterator(base: [*]u8, opt: *align(1) const ImageOptionalHeader64) ImportIterator {
    const dir = dataDir(opt, .IMPORT);
    return .{ .base = base, .desc = if (dir.Size == 0) null else @ptrCast(base + dir.VirtualAddress) };
}

const ImageDirectory = enum(u4) { IMPORT = 1, BASERELOC = 5, TLS = 9, IAT = 12, DELAY_IMPORT = 13, CLR = 14 };
const DataDirectory = extern struct { VirtualAddress: u32, Size: u32 };
const ImageOptionalHeader64 = extern struct {
    Magic: u16,
    MajorLinkerVersion: u8,
    MinorLinkerVersion: u8,
    SizeOfCode: u32,
    SizeOfInitializedData: u32,
    SizeOfUninitializedData: u32,
    AddressOfEntryPoint: u32,
    BaseOfCode: u32,
    ImageBase: u64,
    SectionAlignment: u32,
    FileAlignment: u32,
    MajorOperatingSystemVersion: u16,
    MinorOperatingSystemVersion: u16,
    MajorImageVersion: u16,
    MinorImageVersion: u16,
    MajorSubsystemVersion: u16,
    MinorSubsystemVersion: u16,
    Win32VersionValue: u32,
    SizeOfImage: u32,
    SizeOfHeaders: u32,
    CheckSum: u32,
    Subsystem: u16,
    DllCharacteristics: u16,
    SizeOfStackReserve: u64,
    SizeOfStackCommit: u64,
    SizeOfHeapReserve: u64,
    SizeOfHeapCommit: u64,
    LoaderFlags: u32,
    NumberOfRvaAndSizes: u32,
    DataDirectory: [16]DataDirectory,
};
const ImageNtHeaders64 = extern struct {
    Signature: u32,
    FileHeader: extern struct {
        Machine: u16,
        NumberOfSections: u16,
        TimeDateStamp: u32,
        PointerToSymbolTable: u32,
        NumberOfSymbols: u32,
        SizeOfOptionalHeader: u16,
        Characteristics: u16,
    },
    OptionalHeader: ImageOptionalHeader64,
};
const ImportDescriptor = extern struct {
    OriginalFirstThunk: u32,
    TimeDateStamp: u32,
    ForwarderChain: u32,
    Name: u32,
    FirstThunk: u32,
};
/// The documented prefix of LDR_DATA_TABLE_ENTRY (std's version hides BaseDllName).
const LdrEntry = extern struct {
    InLoadOrderLinks: windows.LIST_ENTRY,
    InMemoryOrderLinks: windows.LIST_ENTRY,
    InInitializationOrderLinks: windows.LIST_ENTRY,
    DllBase: ?*anyopaque,
    EntryPoint: ?*anyopaque,
    SizeOfImage: u32,
    FullDllName: windows.UNICODE_STRING,
    BaseDllName: windows.UNICODE_STRING,
};

const IMAGE_FILE_RELOCS_STRIPPED = 0x0001;
const IMAGE_FILE_EXECUTABLE_IMAGE = 0x0002;
const IMAGE_FILE_DLL = 0x2000;
const IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE = 0x0040;
const IMAGE_FILE_MACHINE_AMD64 = 0x8664;
const DLL_PROCESS_ATTACH = 1;
const THREAD_QUERY_INFORMATION = 0x0040;
const ProcessUserShadowStackPolicy = 13;
const CP_ACP = 0;
const RT_MANIFEST: [*:0]const u16 = @ptrFromInt(24);

/// `image` is the start of the image (the file, or the module in memory), `what`
/// names it for errors (a string or a WTF-16 path).
fn ntHeaders(image: []const u8, what: anytype) error{ExecFailed}!*align(1) const ImageNtHeaders64 {
    const name = if (@TypeOf(what) == []const u16) std.unicode.fmtUtf16Le(what) else what;
    const fmt_name = if (@TypeOf(what) == []const u16) "'{}'" else "{s}";
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return fail(fmt_name ++ " has no MZ signature", .{name});
    const offset = std.mem.readInt(u32, image[0x3c..][0..4], .little);
    if (offset > image.len or image.len - offset < @sizeOf(ImageNtHeaders64)) return fail(fmt_name ++ " has truncated headers", .{name});
    const nt: *align(1) const ImageNtHeaders64 = @ptrCast(image[offset..]);
    if (nt.Signature != 0x4550) return fail(fmt_name ++ " has no PE signature", .{name});
    if (nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64)
        return fail(fmt_name ++ " has machine type 0x{x}, expected x86_64", .{ name, nt.FileHeader.Machine });
    if (nt.OptionalHeader.Magic != 0x20b) return fail(fmt_name ++ " isn't PE32+", .{name});
    return nt;
}
fn dataDir(opt: *align(1) const ImageOptionalHeader64, d: ImageDirectory) DataDirectory {
    return if (@intFromEnum(d) < opt.NumberOfRvaAndSizes) opt.DataDirectory[@intFromEnum(d)] else .{ .VirtualAddress = 0, .Size = 0 };
}

fn fail(comptime fmt: []const u8, args: anytype) error{ExecFailed} {
    log.err("exec: " ++ fmt, args);
    return error.ExecFailed;
}
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.panic("exec: " ++ fmt, args);
}

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]u8;
extern "kernel32" fn GetThreadId(thread: windows.HANDLE) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetProcessMitigationPolicy(process: windows.HANDLE, policy: c_int, buffer: *anyopaque, length: usize) callconv(.winapi) windows.BOOL;
extern "kernel32" fn EnumResourceNamesW(
    module: ?windows.HMODULE,
    type: [*:0]const u16,
    callback: *const fn (?windows.HMODULE, ?[*:0]const u16, ?[*:0]const u16, isize) callconv(.winapi) windows.BOOL,
    param: isize,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WideCharToMultiByte(
    code_page: c_uint,
    flags: windows.DWORD,
    wide: [*]const u16,
    wide_len: c_int,
    multi: ?[*]u8,
    multi_len: c_int,
    default_char: ?[*:0]const u8,
    used_default_char: ?*windows.BOOL,
) callconv(.winapi) c_int;
extern "ntdll" fn NtGetNextThread(
    process: windows.HANDLE,
    thread: ?windows.HANDLE,
    access: windows.ACCESS_MASK,
    attributes: windows.ULONG,
    flags: windows.ULONG,
    new_thread: *windows.HANDLE,
) callconv(.winapi) windows.NTSTATUS;

fn testRemoveArgs(cmd: []const u8, remove: RemoveArgs, expected: anyerror![]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmd_w = try std.unicode.utf8ToUtf16LeAlloc(arena, cmd);
    const result = removeArgs(arena, cmd_w, remove);
    if (expected) |e| {
        try std.testing.expectEqualStrings(e, try std.unicode.utf16LeToUtf8Alloc(arena, try result));
    } else |e| try std.testing.expectError(e, result);
}

test removeArgs {
    try testRemoveArgs("zig version", .{ .start = 0, .count = 0 }, "zig version");
    try testRemoveArgs("zig 0.14.0 build", .{ .start = 1, .count = 1 }, "zig build");
    try testRemoveArgs("zig 0.14.0", .{ .start = 1, .count = 1 }, "zig");
    try testRemoveArgs("zig  0.14.0 \t build  -Dx", .{ .start = 1, .count = 1 }, "zig  build  -Dx");
    try testRemoveArgs("launcher C:\\zig\\zig.exe version", .{ .start = 0, .count = 1 }, "C:\\zig\\zig.exe version");
    try testRemoveArgs("\"C:\\a b\\l.exe\" \"C:\\x y\\zig.exe\" a", .{ .start = 0, .count = 1 }, "\"C:\\x y\\zig.exe\" a");
    try testRemoveArgs("zig 0.14.0 \"a \\\"b\\\" c\" d\\\\", .{ .start = 1, .count = 1 }, "zig \"a \\\"b\\\" c\" d\\\\");
    try testRemoveArgs("zig a b c", .{ .start = 1, .count = 2 }, "zig c");
    try testRemoveArgs("zig a b c", .{ .start = 2, .count = 2 }, "zig a");
    // argv[0] doesn't process escapes, so this one would parse differently as argv[0]
    try testRemoveArgs("launcher \"a\\\"b\" c", .{ .start = 0, .count = 1 }, error.ArgsChanged);
    try testRemoveArgs("zig a", .{ .start = 0, .count = 2 }, error.InvalidRemoveArgs);
    try testRemoveArgs("zig a", .{ .start = 1, .count = 2 }, error.InvalidRemoveArgs);
}
