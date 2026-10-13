const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const Color = std.zig.Color;
const native_os = builtin.os.tag;
const Cache = std.Build.Cache;
const Directory = std.Build.Cache.Directory;
const Dir = std.Io.Dir;
const File = std.Io.File;

const zig = @import("zig");

const Package = zig.Package;

pub const log = std.log;

const hashstore = @import("hashstore.zig");
const Cmdline = @import("Cmdline.zig");
const TmpFile = @import("TmpFile.zig");
const lockfile = @import("lockfile.zig");
const logging = @import("logging.zig");
const AppData = @import("AppData.zig");

pub const std_options: std.Options = .{
    .logFn = logging.logFn,
};

/// not global_single_threaded, it can't allocate and has no environ, which spawning needs
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();

const exe_str = @tagName(build_options.exe);

const global = struct {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_instance.allocator();

    var root_progress_node: ?std.Progress.Node = null;
    fn getRootProgressNode() std.Progress.Node {
        if (root_progress_node == null) {
            root_progress_node = std.Progress.start(io, .{ .root_name = "anyzig" });
        }
        return root_progress_node.?;
    }
};

fn initProxies(client: *std.http.Client, arena: Allocator, environ: process.Environ) !void {
    var environ_map: process.Environ.Map = .init(arena);
    defer environ_map.deinit();
    inline for (.{ "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }) |name| {
        const value = if (native_os == .windows)
            if (environ.getWindows(comptime std.unicode.wtf8ToWtf16LeStringLiteral(name))) |v|
                try std.unicode.wtf16LeToWtf8Alloc(arena, v)
            else
                null
        else
            environ.getPosix(name);
        if (value) |v| try environ_map.put(name, v);
    }
    try client.initDefaultProxies(arena, &environ_map);
}

fn filePrint(file: File, comptime fmt: []const u8, args: anytype) File.Writer.Error!void {
    var buf: [1024]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buf);
    file_writer.interface.print(fmt, args) catch return file_writer.err.?;
    file_writer.interface.flush() catch return file_writer.err.?;
}

const Extent = struct { start: usize, limit: usize };

const key_minimum_zig_version = ".minimum_zig_version";
const key_zig_version = ".zig_version";
const key_mach_zig_version = ".mach_zig_version";

fn extractZigVersion(zon: []const u8, needle: []const u8) ?Extent {
    var offset: usize = 0;
    while (true) {
        offset = skipWhitespaceAndComments(zon, offset);
        const minimum_zig_version = std.mem.findPos(u8, zon, offset, needle) orelse return null;
        offset = skipWhitespaceAndComments(zon, minimum_zig_version + needle.len);
        if (zonInsideComment(zon, minimum_zig_version))
            continue;
        if (offset >= zon.len or zon[offset] != '=') {
            log.debug("build.zig.zon syntax error (missing '=' after '{s}')", .{needle});
            return null;
        }
        offset = skipWhitespaceAndComments(zon, offset + 1);
        if (offset >= zon.len or zon[offset] != '\"') {
            log.debug("build.zig.zon syntax error", .{});
            return null;
        }
        const version_start = offset + 1;
        while (true) {
            offset += 1;
            if (offset >= zon.len) {
                log.debug("build.zig.zon syntax error", .{});
                return null;
            }
            if (zon[offset] == '"') break;
        }
        return .{ .start = version_start, .limit = offset };
    }
}

fn zonInsideComment(zon: []const u8, start: usize) bool {
    if (start < 2) return false;
    if (zon[start - 1] == '\n') return false;
    var offset = start - 2;
    while (true) : (offset -= 1) {
        if (zon[offset] == '\n') return false;
        if (zon[offset] == '/' and zon[offset + 1] == '/') return true;
        if (offset == 0) return false;
    }
    return false;
}

fn skipWhitespaceAndComments(s: []const u8, start: usize) usize {
    var offset = start;
    var previous_was_slash = false;
    while (offset < s.len) {
        const double_slash = blk: {
            const at_slash = s[offset] == '/';
            const double_slash = previous_was_slash and at_slash;
            previous_was_slash = at_slash;
            break :blk double_slash;
        };
        if (double_slash) {
            while (true) {
                offset += 1;
                if (offset == s.len) break;
                if (s[offset] == '\n') {
                    offset += 1;
                    break;
                }
            }
        } else if (!std.ascii.isWhitespace(s[offset])) {
            break;
        } else {
            offset += 1;
        }
    }
    return offset;
}

fn loadBuildZigZon(arena: Allocator, build_root: BuildRoot) !?[]const u8 {
    return build_root.directory.handle.readFileAlloc(io, "build.zig.zon", arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return entryErr("read", build_root.directory.path orelse ".", "build.zig.zon", e),
    };
}

fn isMachVersion(v: SemanticVersion) bool {
    if (v.build == null) {
        if (v.pre) |*pre| return std.mem.eql(u8, pre.slice(), "mach");
    }
    return false;
}

fn determineSemanticVersion(scratch: Allocator, build_root: BuildRoot) !SemanticVersion {
    const zon = try loadBuildZigZon(scratch, build_root) orelse {
        log.err("TODO: no build.zig.zon file, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };
    defer scratch.free(zon);

    for ([_][]const u8{
        key_mach_zig_version,
        key_zig_version,
        key_minimum_zig_version,
    }) |key_version| {
        const version_extent = extractZigVersion(zon, key_version) orelse continue;
        const version = zon[version_extent.start..version_extent.limit];

        if (key_version.ptr == key_mach_zig_version.ptr) {
            if (!std.mem.endsWith(u8, version, "-mach")) errExit(
                "expected the " ++ key_mach_zig_version ++ " to end with '-mach' but got '{s}'",
                .{version},
            );
        }

        log.info(
            "{s} '{s}' pulled from '{f}build.zig.zon'",
            .{ key_version, version, build_root.directory },
        );
        return SemanticVersion.parse(version) orelse errExit(
            "{f}build.zig.zon has invalid {s} \"{s}\"",
            .{ build_root.directory, key_version, version },
        );
    }

    errExit(
        "build.zig.zon is missing minimum_zig_version, either add it or run '{s} VERSION' to specify a version",
        .{@tagName(build_options.exe)},
    );

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: if we find ".{ .path = "..." }" in build.zig then we know zig must be older than 0.13.0

    // 0.12.0
    // <         .root_source_file = b.path("src/root.zig"),
    // 0.11.0
    // >         .root_source_file = .{ .path = "src/main.zig" },

    // log.info("fallback to default zig version 0.13.0", .{});
    // return "0.13.0";
}

pub fn main(init: process.Init.Minimal) !void {
    run(init) catch |err| switch (err) {
        error.Reported => process.exit(1),
        else => |e| return e,
    };
}

fn run(init: process.Init.Minimal) !void {
    defer _ = global.debug_allocator.deinit();
    const gpa = global.gpa;

    threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();

    defer if (global.root_progress_node) |n| {
        n.end();
    };

    defer global.arena_instance.deinit();
    const arena = global.arena;

    const app_data = try AppData.init(arena, init.environ);
    logging.global.context = .{ .app_data = app_data, .io = io };
    defer logging.global.context = null;

    const cmdline: Cmdline = try .init(init.args, arena);

    const cmdline_offset: usize, const manual_version: ?VersionSpecifier = blk: {
        if (cmdline.len() >= 2) {
            if (VersionSpecifier.parse(cmdline.arg(1))) |v| break :blk .{ 2, v };
        }
        break :blk .{ 1, null };
    };

    const maybe_command: ?[]const u8 = if (cmdline_offset >= cmdline.len()) null else cmdline.arg(cmdline_offset);

    const build_root_options = blk: {
        var options: FindBuildRootOptions = .{};
        switch (build_options.exe) {
            .zig => {
                if (maybe_command) |command| {
                    if (std.mem.eql(u8, command, "build")) {
                        var index: usize = cmdline_offset + 1;
                        while (index < cmdline.len()) : (index += 1) {
                            const arg = cmdline.arg(index);
                            if (std.mem.eql(u8, arg, "--build-file")) {
                                index += 1;
                                if (index == cmdline.len()) errExit("--build-file requires an argument", .{});
                                options.build_file = cmdline.arg(index);
                                log.info("build file '{s}'", .{options.build_file.?});
                            }
                        }
                    }
                }
            },
            .zls => {},
        }
        break :blk options;
    };

    const version_specifier: VersionSpecifier, const is_init = blk: {
        if (maybe_command) |command| {
            if (std.mem.startsWith(u8, command, "-") and !std.mem.eql(u8, command, "-h") and !std.mem.eql(u8, command, "--help")) {
                try filePrint(.stderr(), "error: expected a command but got '{s}'\n", .{command});
                std.process.exit(0xff);
            }
            if (build_options.exe == .zig and (std.mem.eql(u8, command, "init") or std.mem.eql(u8, command, "init-exe") or std.mem.eql(u8, command, "init-lib"))) {
                const is_help = blk_is_help: {
                    var index: usize = cmdline_offset + 1;
                    while (index < cmdline.len()) : (index += 1) {
                        const arg = cmdline.arg(index);
                        if (std.mem.eql(u8, arg, "-h")) break :blk_is_help true;
                        if (std.mem.eql(u8, arg, "--help")) break :blk_is_help true;
                    } else break :blk_is_help false;
                };

                if (manual_version) |version| break :blk .{ version, !is_help };
                try filePrint(.stderr(), "error: anyzig init requires a version, i.e. 'zig 0.13.0 {s}'\n", .{command});
                std.process.exit(0xff);
            }
            if (std.mem.eql(u8, command, "any")) std.process.exit(try anyCommand(cmdline, cmdline_offset + 1, app_data));
        }
        if (manual_version) |version| break :blk .{ version, false };
        const build_root = try findBuildRoot(arena, build_root_options) orelse {
            try File.stderr().writeStreamingAll(
                io,
                "no build.zig to pull a zig version from, you can:\n" ++
                    "  1. run '" ++ exe_str ++ " VERSION' to specify a version\n" ++
                    "  2. run from a directory where a build.zig can be found\n",
            );
            std.process.exit(0xff);
        };
        break :blk .{ .{ .semantic = try determineSemanticVersion(arena, build_root) }, false };
    };

    const app_data_path = app_data.path;
    log.info("appdata '{s}'", .{app_data_path});

    const semantic_version = semantic_version: switch (version_specifier) {
        .semantic => |v| v,
        .master => {
            const download_index_kind: DownloadIndexKind = .official;
            const index_path = try Dir.path.join(arena, &.{ app_data_path, download_index_kind.basename() });
            defer arena.free(index_path);
            try fetchFile(arena, init.environ, app_data_path, download_index_kind.uri(), index_path);
            // since we just downloaded the file, this should always succeed now
            const index_content = try Dir.cwd().readFileAlloc(io, index_path, arena, .unlimited);
            defer arena.free(index_content);
            break :semantic_version extractMasterVersion(arena, index_path, index_content);
        },
    };
    if (version_specifier == .master) {
        std.log.info("master is at {f}", .{semantic_version});
    }

    var versioned_exe_buf: [Dir.max_path_bytes]u8 = undefined;
    const versioned_exe = std.fmt.bufPrintSentinel(
        &versioned_exe_buf,
        "{s}" ++ install_sub_path_fmt ++ exe_basename,
        .{ app_data_path, semantic_version },
        0,
    ) catch errExit("appdata path '{s}' is too long", .{app_data_path});
    const install_path = versioned_exe[0 .. versioned_exe.len - Dir.path.sep_str.len - exe_basename.len];

    if (Dir.cwd().access(io, versioned_exe, .{})) |_| {
        log.info("{s} '{f}' already exists at '{s}'", .{ exe_str, semantic_version, install_path });
    } else |err| switch (err) {
        error.FileNotFound => try install(gpa, arena, init.environ, app_data_path, &semantic_version, install_path),
        else => |e| return pathErr("access", versioned_exe, e),
    }

    const stay_alive = is_init or (native_os == .windows);

    if (stay_alive) {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: if on windows, create a job so our child process gets killed if
        //       our process gets killed
        if (native_os == .windows) {
            const windows = std.os.windows;
            const handle = try spawnWindows(arena, versioned_exe, cmdline, cmdline_offset);
            // not Child.wait, it truncates the exit code to a u8 (e.g. 0xC0000005 => 5)
            switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null)) {
                .WAIT_0 => {},
                else => |status| std.debug.panic("NtWaitForSingleObject failed, status={t}", .{status}),
            }
            var info: windows.PROCESS.BASIC_INFORMATION = undefined;
            switch (windows.ntdll.NtQueryInformationProcess(
                handle,
                .BasicInformation,
                &info,
                @sizeOf(windows.PROCESS.BASIC_INFORMATION),
                null,
            )) {
                .SUCCESS => {},
                else => |status| std.debug.panic("NtQueryInformationProcess failed, status={t}", .{status}),
            }
            const code: u32 = @bitCast(@backingInt(info.ExitStatus));
            if (code != 0) windows.ntdll.RtlExitUserProcess(code);
        } else {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.append(arena, versioned_exe);
            for (cmdline_offset..cmdline.len()) |arg_index| {
                try argv.append(arena, cmdline.arg(arg_index));
            }
            var child = try process.spawn(io, .{ .argv = argv.items });
            switch (try child.wait(io)) {
                .exited => |code| if (code != 0) std.process.exit(code),
                else => std.process.exit(0xff),
            }
        }
    }

    if (is_init) {
        const build_root = try findBuildRoot(arena, build_root_options) orelse @panic("init did not create a build.zig file");
        log.info("{f}{s}", .{ build_root.directory, build_root.build_zig_basename });
        const zon = try loadBuildZigZon(arena, build_root) orelse {
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: maybe don't use .name = placeholder?
            try writeFilePrint("build.zig.zon",
                \\.{{
                \\    .name = "placeholder",
                \\    .version = "0.0.0",
                \\    .minimum_zig_version = "{f}",
                \\}}
                \\
            , .{semantic_version});
            return;
        };
        const version_extent = extractZigVersion(zon, key_minimum_zig_version) orelse {
            if (!std.mem.startsWith(u8, zon, ".{")) @panic("zon file did not start with '.{'");
            if (zon.len < 2 or zon[2] != '\n') @panic("zon file not start with '.{\\n");
            try writeFilePrint(
                "build.zig.zon",
                "{s}    .minimum_zig_version = \"{f}\",\n{s}",
                .{ zon[0..3], semantic_version, zon[3..] },
            );
            return;
        };

        const generated_version_str = zon[version_extent.start..version_extent.limit];
        const generated_version = SemanticVersion.parse(generated_version_str) orelse errExit(
            "unable to parse zig version '{s}' generated by init",
            .{generated_version_str},
        );
        if (generated_version.eql(semantic_version))
            return;
        std.debug.panic(
            "zig init generated version '{f}' but expected '{f}'",
            .{ generated_version, semantic_version },
        );
    }

    if (!stay_alive) {
        // not std.process.replace, it removes ZIG_PROGRESS from the environment
        const args = init.args.vector;
        const argv = try arena.allocSentinel(?[*:0]const u8, args.len - cmdline_offset + 1, null);
        argv[0] = versioned_exe;
        for (args[cmdline_offset..], argv[1..]) |arg, *dest| dest.* = arg;
        const rc = std.posix.system.execve(versioned_exe, argv, init.environ.block.slice.ptr);
        log.err("exec '{s}' failed with E{t}", .{ versioned_exe, std.posix.errno(rc) });
        process.exit(0xff);
    }
}

/// not std.process.spawn, it removes ZIG_PROGRESS from the child's environment
fn spawnWindows(
    arena: Allocator,
    exe: [:0]const u8,
    cmdline: Cmdline,
    cmdline_offset: usize,
) error{OutOfMemory}!std.os.windows.HANDLE {
    const windows = std.os.windows;

    // serialized for CommandLineToArgvW, same as std's (private) argvToCommandLineWindows
    var cmd: std.ArrayList(u8) = .empty;
    if (std.mem.findScalar(u8, exe, '"')) |_| errExit("exe path '{s}' contains a double quote", .{exe});
    const exe_needs_quotes = for (exe) |c| {
        if (c <= ' ') break true;
    } else false;
    if (exe_needs_quotes) try cmd.append(arena, '"');
    try cmd.appendSlice(arena, exe);
    if (exe_needs_quotes) try cmd.append(arena, '"');
    for (cmdline_offset..cmdline.len()) |arg_index| {
        const arg = cmdline.arg(arg_index);
        try cmd.append(arena, ' ');
        const needs_quotes = for (arg) |c| {
            if (c <= ' ' or c == '"') break true;
        } else arg.len == 0;
        if (!needs_quotes) {
            try cmd.appendSlice(arena, arg);
            continue;
        }
        try cmd.append(arena, '"');
        var backslash_count: usize = 0;
        for (arg) |c| switch (c) {
            '\\' => backslash_count += 1,
            '"' => {
                try cmd.appendNTimes(arena, '\\', backslash_count * 2 + 1);
                try cmd.append(arena, '"');
                backslash_count = 0;
            },
            else => {
                try cmd.appendNTimes(arena, '\\', backslash_count);
                try cmd.append(arena, c);
                backslash_count = 0;
            },
        };
        try cmd.appendNTimes(arena, '\\', backslash_count * 2);
        try cmd.append(arena, '"');
    }

    const exe_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, exe) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidWtf8 => errExit("exe path '{s}' is not valid WTF-8", .{exe}),
    };
    const cmd_w = std.unicode.wtf8ToWtf16LeAllocZ(arena, cmd.items) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // our args came from the WTF-16 command line so they're always valid WTF-8
        error.InvalidWtf8 => unreachable,
    };

    const params = windows.peb().ProcessParameters;
    var startup_info: windows.STARTUPINFOW = .{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .dwFlags = windows.STARTF_USESTDHANDLES,
        .hStdInput = params.hStdInput,
        .hStdOutput = params.hStdOutput,
        .hStdError = params.hStdError,
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
    };
    var process_info: windows.PROCESS.INFORMATION = undefined;
    if (!windows.kernel32.CreateProcessW(
        exe_w,
        cmd_w,
        null,
        null,
        .TRUE,
        .{},
        null, // inherit our environment
        null,
        &startup_info,
        &process_info,
    ).toBool()) errExit("CreateProcess '{s}' failed, error={t}", .{ exe, windows.GetLastError() });
    windows.CloseHandle(process_info.hThread);
    return process_info.hProcess;
}

fn writeFilePrint(path: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const file = try Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    file_writer.interface.print(fmt, args) catch return file_writer.err.?;
    file_writer.interface.flush() catch return file_writer.err.?;
}

/// Installs are prepared under a per-version lock and renamed into place when complete, so
/// finding one takes no lock. An install dir whose lock isn't held was abandoned.
const install_sub_path_fmt = Dir.path.sep_str ++ exe_str ++ Dir.path.sep_str ++ "{f}" ++ Dir.path.sep_str;
const exe_basename = exe_str ++ builtin.target.exeFileExt();

fn install(
    gpa: Allocator,
    arena: Allocator,
    environ: process.Environ,
    app_data_path: []const u8,
    version: *const SemanticVersion,
    install_path: []const u8,
) !void {
    const name_buf = hashstoreName(version);
    const name = name_buf.slice();

    const installing_path = try Dir.path.join(arena, &.{ app_data_path, "install" });
    var installing_dir = Dir.cwd().createDirPathOpen(io, installing_path, .{
        .open_options = .{ .iterate = true },
    }) catch |err| return pathErr("create directory", installing_path, err);
    defer installing_dir.close(io);

    var lock_name_buf: [name_buf.buf.len + ".lock".len]u8 = undefined;
    const lock_name = std.fmt.bufPrint(&lock_name_buf, "{s}.lock", .{name}) catch unreachable;
    // never deleted, another process could be waiting on it
    const lock_file = lockfile.createOrOpen(io, installing_dir, lock_name) catch |err|
        return entryErr("create or open", installing_path, lock_name, err);
    // releases the lock
    defer lock_file.close(io);
    if (!(lock_file.tryLock(io, .exclusive) catch |err| return entryErr("lock", installing_path, lock_name, err))) {
        log.info("waiting for another anyzig to finish installing {s}", .{name});
        lock_file.lock(io, .exclusive) catch |err| return entryErr("lock", installing_path, lock_name, err);
    }

    {
        var exe_path_buf: [Dir.max_path_bytes]u8 = undefined;
        const exe_path = std.fmt.bufPrint(&exe_path_buf, "{s}" ++ Dir.path.sep_str ++ exe_basename, .{install_path}) catch
            return reportErr("install path '{s}' is too long", .{install_path});
        if (Dir.cwd().access(io, exe_path, .{})) |_| {
            log.info("{s} was installed by another process", .{name});
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return pathErr("access", exe_path, e),
        }
        if (Dir.cwd().access(io, install_path, .{})) |_| {
            log.warn("'{s}' exists without '{s}', deleting it", .{ install_path, exe_basename });
            Dir.cwd().deleteTree(io, install_path) catch |err| return pathErr("delete", install_path, err);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return pathErr("access", install_path, e),
        }
    }

    try cleanAbandonedInstalls(installing_dir, installing_path, name);
    // we hold the lock, so if this exists it was left by a process that died
    if (installing_dir.access(io, name, .{})) |_| {
        log.info("deleting abandoned install '{s}{c}{s}'", .{ installing_path, Dir.path.sep, name });
        installing_dir.deleteTree(io, name) catch |err| return entryErr("delete", installing_path, name, err);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return entryErr("access", installing_path, name, e),
    }
    defer installing_dir.deleteTree(io, name) catch |err| log.warn(
        "failed to delete '{s}{c}{s}': {t}",
        .{ installing_path, Dir.path.sep, name, err },
    );
    {
        const parent = Dir.path.dirname(install_path).?;
        Dir.cwd().createDirPath(io, parent) catch |err| return pathErr("create directory", parent, err);
    }

    const prepared_path = try Dir.path.join(arena, &.{ installing_path, name });
    if (try findLegacyInstall(arena, environ, app_data_path, name)) |legacy_path| {
        log.info("copying {s} from '{s}' where an older anyzig installed it", .{ name, legacy_path });
        {
            var src = Dir.cwd().openDir(io, legacy_path, .{ .iterate = true }) catch |err|
                return pathErr("open directory", legacy_path, err);
            defer src.close(io);
            var dest = installing_dir.createDirPathOpen(io, name, .{}) catch |err|
                return pathErr("create directory", prepared_path, err);
            defer dest.close(io);
            var src_path: PathBuf = try .init(legacy_path);
            var dest_path: PathBuf = try .init(prepared_path);
            try copyTree(src, &src_path, dest, &dest_path);
        }
        try moveIntoPlace(prepared_path, install_path);
        log.info("copied {s} to '{s}'", .{ name, install_path });
        return;
    }

    const url = try getVersionUrl(arena, environ, app_data_path, version.*);
    defer url.deinit(arena);
    const hash = try cmdFetch(gpa, arena, environ, prepared_path, url.fetch);
    const fetched_path = try Dir.path.join(arena, &.{ prepared_path, hash.toSlice() });
    try moveIntoPlace(fetched_path, install_path);
    log.info("downloaded {s} to '{s}'", .{ name, install_path });
}

fn cleanAbandonedInstalls(installing_dir: Dir, installing_path: []const u8, skip_name: []const u8) !void {
    var it = installing_dir.iterate();
    while (it.next(io) catch |err| return pathErr("iterate directory", installing_path, err)) |entry| {
        if (try entryKind(installing_dir, installing_path, entry) != .directory) continue;
        if (std.mem.eql(u8, entry.name, skip_name)) continue;
        var lock_name_buf: [Dir.max_name_bytes]u8 = undefined;
        const lock_name = std.fmt.bufPrint(&lock_name_buf, "{s}.lock", .{entry.name}) catch return reportErr(
            "unexpected directory '{s}{c}{s}', its name is too long",
            .{ installing_path, Dir.path.sep, entry.name },
        );
        // the lock file is created before the directory and never deleted
        const lock_file = installing_dir.openFile(io, lock_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                log.info("deleting install '{s}{c}{s}', it has no lock file", .{ installing_path, Dir.path.sep, entry.name });
                installing_dir.deleteTree(io, entry.name) catch |e| return entryErr("delete", installing_path, entry.name, e);
                continue;
            },
            else => |e| return entryErr("open", installing_path, lock_name, e),
        };
        defer lock_file.close(io);
        if (!(lock_file.tryLock(io, .exclusive) catch |err| return entryErr("lock", installing_path, lock_name, err))) continue;
        log.info("deleting abandoned install '{s}{c}{s}'", .{ installing_path, Dir.path.sep, entry.name });
        installing_dir.deleteTree(io, entry.name) catch |err| return entryErr("delete", installing_path, entry.name, err);
    }
}

fn moveIntoPlace(src_path: []const u8, install_path: []const u8) !void {
    Dir.rename(.cwd(), src_path, .cwd(), install_path, io) catch |err|
        return reportErr("rename '{s}' to '{s}' failed with {t}", .{ src_path, install_path, err });
}

const PathBuf = struct {
    bytes: [Dir.max_path_bytes]u8,
    len: usize,

    fn init(path: []const u8) error{Reported}!PathBuf {
        var result: PathBuf = .{ .bytes = undefined, .len = path.len };
        if (path.len > result.bytes.len) return reportErr("path '{s}' is too long", .{path});
        @memcpy(result.bytes[0..path.len], path);
        return result;
    }

    fn slice(p: *const PathBuf) []const u8 {
        return p.bytes[0..p.len];
    }

    fn push(p: *PathBuf, name: []const u8) error{Reported}!usize {
        const old_len = p.len;
        const new_len = old_len + 1 + name.len;
        if (new_len > p.bytes.len) return reportErr("path '{s}' + '{s}' is too long", .{ p.slice(), name });
        p.bytes[old_len] = Dir.path.sep;
        @memcpy(p.bytes[old_len + 1 ..][0..name.len], name);
        p.len = new_len;
        return old_len;
    }
};

fn copyTree(src: Dir, src_path: *PathBuf, dest: Dir, dest_path: *PathBuf) !void {
    var it = src.iterate();
    while (it.next(io) catch |err| return pathErr("iterate directory", src_path.slice(), err)) |entry| {
        switch (try entryKind(src, src_path.slice(), entry)) {
            .file => Dir.copyFile(src, entry.name, dest, entry.name, io, .{}) catch |err| return reportErr(
                "copy '{s}{c}{s}' to '{s}{c}{s}' failed with {t}",
                .{ src_path.slice(), Dir.path.sep, entry.name, dest_path.slice(), Dir.path.sep, entry.name, err },
            ),
            .directory => {
                const src_restore = try src_path.push(entry.name);
                defer src_path.len = src_restore;
                const dest_restore = try dest_path.push(entry.name);
                defer dest_path.len = dest_restore;
                var sub_src = src.openDir(io, entry.name, .{ .iterate = true }) catch |err|
                    return pathErr("open directory", src_path.slice(), err);
                defer sub_src.close(io);
                var sub_dest = dest.createDirPathOpen(io, entry.name, .{}) catch |err|
                    return pathErr("create directory", dest_path.slice(), err);
                defer sub_dest.close(io);
                try copyTree(sub_src, src_path, sub_dest, dest_path);
            },
            // zig release archives only contain files and directories
            else => |kind| return reportErr(
                "can't copy '{s}" ++ Dir.path.sep_str ++ "{s}', unexpected kind {t}",
                .{ src_path.slice(), entry.name, kind },
            ),
        }
    }
}

/// some filesystems don't report entry kinds (std gives .unknown)
fn entryKind(dir: Dir, dir_path: []const u8, entry: Dir.Entry) !File.Kind {
    if (entry.kind != .unknown) return entry.kind;
    const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err|
        return entryErr("stat", dir_path, entry.name, err);
    return stat.kind;
}

fn reportErr(comptime format: []const u8, args: anytype) error{Reported} {
    log.err(format, args);
    return error.Reported;
}
fn pathErr(op: []const u8, path: []const u8, err: anyerror) error{Reported} {
    log.err("{s} '{s}' failed with {t}", .{ op, path, err });
    return error.Reported;
}
fn entryErr(op: []const u8, dir_path: []const u8, name: []const u8, err: anyerror) error{Reported} {
    log.err("{s} '{s}{c}{s}' failed with {t}", .{ op, dir_path, Dir.path.sep, name, err });
    return error.Reported;
}

/// pre-0.17 anyzig installed into zig's global cache (p/<hash>, found via the hashstore).
/// These are copied, not moved, it's zig's cache and older anyzig versions still use them.
fn findLegacyInstall(arena: Allocator, environ: process.Environ, app_data_path: []const u8, name: []const u8) !?[]const u8 {
    const hashstore_path = try Dir.path.join(arena, &.{ app_data_path, "hashstore" });
    const hash = switch (try hashstore.find(io, hashstore_path, name)) {
        .not_found, .invalid => return null,
        .found => |hash| hash,
    };
    const global_cache_path = AppData.legacyGlobalCacheDir(arena, environ) orelse {
        log.info("hashstore has {s} but zig's global cache directory is unknown", .{name});
        return null;
    };
    const path = try Dir.path.join(arena, &.{ global_cache_path, "p", hash.toSlice() });
    const exe_path = try Dir.path.join(arena, &.{ path, exe_basename });
    Dir.cwd().access(io, exe_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("hashstore has {s} but '{s}' doesn't exist", .{ name, exe_path });
            return null;
        },
        else => |e| return pathErr("access", exe_path, e),
    };
    return path;
}

fn anyCommandUsage() !u8 {
    try filePrint(
        .stderr(),
        "any" ++ @tagName(build_options.exe) ++ " {s} from https://github.com/marler8997/anyzig\n" ++
            "Here are the anyzig-specific subcommands:\n" ++
            "  zig any set-verbosity LEVEL    | sets the default system-wide verbosity\n" ++
            "                                 | accepts 'warn' or 'debug'\n" ++
            "  zig any version                | print the version of anyzig to stdout\n" ++
            "  zig any list-installed         | list all versions of zig installed by anyzig\n",
        .{@embedFile("version")},
    );
    return 0xff;
}

fn anyCommand(cmdline: Cmdline, cmdline_offset: usize, app_data: AppData) !u8 {
    if (cmdline_offset == cmdline.len()) {
        std.process.exit(try anyCommandUsage());
    }
    const command = cmdline.arg(cmdline_offset);
    const arg_offset = cmdline_offset + 1;

    if (std.mem.eql(u8, command, "version")) {
        if (arg_offset < cmdline.len()) errExit("the 'version' subcommand does not take any cmdline args", .{});
        try filePrint(.stdout(), "{s}\n", .{@embedFile("version")});
        return 0;
    } else if (std.mem.eql(u8, command, "set-verbosity")) {
        if (arg_offset >= cmdline.len()) errExit("missing VERBOSITY (either 'warn' or 'debug')", .{});
        if (arg_offset + 1 < cmdline.len()) errExit("too many cmdline args", .{});
        const level_str = cmdline.arg(arg_offset);
        const level: logging.Verbosity = blk: {
            if (std.mem.eql(u8, level_str, "warn")) break :blk .warn;
            if (std.mem.eql(u8, level_str, "debug")) break :blk .debug;
            errExit("unknown VERBOSITY '{s}', expected 'warn' or 'debug'", .{level_str});
        };
        {
            const tmp_path = Dir.path.join(global.arena, &.{ app_data.path, "tmp" }) catch |e| oom(e);
            defer global.arena.free(tmp_path);
            // every anyzig process reads this file, so replace it atomically, otherwise a
            // process could read it after it's been truncated but before it's written
            var tmp_file = try TmpFile.create(io, tmp_path);
            defer tmp_file.deinit(io);
            try filePrint(tmp_file.file, "{s}\n", .{level_str});
            try tmp_file.finish(io, app_data.verbosity_path);
        }
        switch (logging.readVerbosityFile(io, app_data)) {
            .no_file => @panic("no file after writing it?"),
            .loaded_from_file => |l| std.debug.assert(l == level),
        }
        return 0;
    } else if (std.mem.eql(u8, command, "list-installed")) {
        if (arg_offset < cmdline.len()) errExit("the 'list-installed' subcommand does not take any cmdline args", .{});
        try listInstalled(app_data);
        return 0;
    } else errExit("unknown zig any '{s}' command", .{command});
}

fn listInstalled(app_data: AppData) !void {
    const installs_path = try Dir.path.join(global.arena, &.{ app_data.path, exe_str });

    var installs_dir = Dir.cwd().openDir(io, installs_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // nothing installed yet
        else => |e| return pathErr("open directory", installs_path, e),
    };
    defer installs_dir.close(io);

    const Installed = struct {
        version: SemanticVersion,
        name: []const u8,
        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.version.ref().order(b.version.ref()) == .lt;
        }
    };
    var installed: std.ArrayList(Installed) = .empty;
    var it = installs_dir.iterate();
    while (it.next(io) catch |err| return pathErr("iterate directory", installs_path, err)) |entry| {
        const kind = try entryKind(installs_dir, installs_path, entry);
        const version = SemanticVersion.parse(entry.name) orelse {
            log.warn("unexpected {t} '{s}{c}{s}', expected a directory named after a version", .{
                kind, installs_path, Dir.path.sep, entry.name,
            });
            continue;
        };
        if (kind != .directory) {
            log.warn("unexpected {t} '{s}{c}{s}', expected a directory", .{
                kind, installs_path, Dir.path.sep, entry.name,
            });
            continue;
        }
        installed.append(global.arena, .{
            .version = version,
            .name = global.arena.dupe(u8, entry.name) catch |e| oom(e),
        }) catch |e| oom(e);
    }
    std.mem.sort(Installed, installed.items, {}, Installed.lessThan);
    for (installed.items) |i| {
        try filePrint(.stdout(), "{f}\t{s}{c}{s}\n", .{ i.version, installs_path, Dir.path.sep, i.name });
    }
}

fn hashstoreName(version: *const SemanticVersion) BoundedString(exe_str.len + 1 + SemanticVersion.max_string) {
    var result: BoundedString(exe_str.len + 1 + SemanticVersion.max_string) = undefined;
    const name = std.fmt.bufPrint(&result.buf, exe_str ++ "-{f}", .{version}) catch unreachable;
    result.len = @intCast(name.len);
    return result;
}

fn BoundedString(comptime max: usize) type {
    return struct {
        buf: [max]u8,
        len: std.math.IntFittingRange(0, max),
        const Self = @This();
        fn init(s: []const u8) ?Self {
            if (s.len > max) return null;
            var result: Self = .{ .buf = undefined, .len = @intCast(s.len) };
            @memcpy(result.buf[0..s.len], s);
            return result;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const SemanticVersion = struct {
    const max_pre = 50;
    const max_build = 50;
    const max_string = 50 + max_pre + max_build;

    major: usize,
    minor: usize,
    patch: usize,
    pre: ?BoundedString(max_pre),
    build: ?BoundedString(max_build),

    pub fn array(self: *const SemanticVersion) BoundedString(max_string) {
        var result: BoundedString(max_string) = undefined;
        const roundtrip = std.fmt.bufPrint(&result.buf, "{f}", .{self}) catch unreachable;
        result.len = @intCast(roundtrip.len);
        return result;
    }

    pub fn parse(s: []const u8) ?SemanticVersion {
        const parsed = std.SemanticVersion.parse(s) catch |e| switch (e) {
            error.Overflow, error.InvalidVersion => return null,
        };
        std.debug.assert(s.len <= max_string);

        const result: SemanticVersion = .{
            .major = parsed.major,
            .minor = parsed.minor,
            .patch = parsed.patch,
            .pre = if (parsed.pre) |pre| BoundedString(max_pre).init(pre) orelse std.debug.panic(
                "semantic version pre '{s}' is too long (max is {})",
                .{ pre, max_pre },
            ) else null,
            .build = if (parsed.build) |build| BoundedString(max_build).init(build) orelse std.debug.panic(
                "semantic version build '{s}' is too long (max is {})",
                .{ build, max_build },
            ) else null,
        };

        {
            // sanity check, ensure format gives us the same string back we just parsed
            const roundtrip = result.array();
            if (!std.mem.eql(u8, roundtrip.slice(), s)) errExit(
                "codebug parse/format version mismatch:\nparsed: '{s}'\nformat: '{s}'\n",
                .{ s, roundtrip.slice() },
            );
        }

        return result;
    }
    pub fn ref(self: *const SemanticVersion) std.SemanticVersion {
        return .{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (self.pre) |*pre| pre.slice() else null,
            .build = if (self.build) |*build| build.slice() else null,
        };
    }
    pub fn eql(self: SemanticVersion, other: SemanticVersion) bool {
        return self.ref().order(other.ref()) == .eq;
    }
    pub fn format(self: *const SemanticVersion, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.ref().format(w);
    }
};

const VersionSpecifier = union(enum) {
    master,
    semantic: SemanticVersion,
    pub fn parse(s: []const u8) ?VersionSpecifier {
        if (SemanticVersion.parse(s)) |v| return .{ .semantic = v };
        return switch (build_options.exe) {
            .zig => return if (std.mem.eql(u8, s, "master")) .master else null,
            .zls => return null,
        };
    }
};

const arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .powerpc64 => "powerpc64",
    .powerpc64le => "powerpc64le",
    .riscv64 => "riscv64",
    .s390x => "s390x",
    .x86 => "x86",
    .x86_64 => "x86_64",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (native_os) {
    .freebsd => "freebsd",
    .linux => "linux",
    .macos => "macos",
    .netbsd => "netbsd",
    .windows => "windows",
    else => @compileError("Unsupported OS"),
};

const os_arch = os ++ "-" ++ arch;
const arch_os = arch ++ "-" ++ os;
const archive_ext = if (native_os == .windows) "zip" else "tar.xz";

const VersionKind = union(enum) { release: Release, dev };
fn determineVersionKind(v: SemanticVersion) VersionKind {
    return if (v.pre == null and v.build == null) .{ .release = .{
        .major = v.major,
        .minor = v.minor,
        .patch = v.patch,
    } } else .dev;
}

const DownloadIndexKind = enum {
    official,
    mach,
    pub fn url(self: DownloadIndexKind) []const u8 {
        return switch (self) {
            .official => "https://ziglang.org/download/index.json",
            .mach => "https://pkg.hexops.org/zig/index.json",
        };
    }
    pub fn uri(self: DownloadIndexKind) std.Uri {
        return std.Uri.parse(self.url()) catch unreachable;
    }
    pub fn basename(self: DownloadIndexKind) []const u8 {
        return switch (self) {
            .official => "download-index.json",
            .mach => "download-index-mach.json",
        };
    }
};

const DownloadUrl = struct {
    // use to know if two URL's are the same
    official: []const u8,
    // the actual URL to fetch from
    fetch: []const u8,
    pub fn initOfficial(url: []const u8) DownloadUrl {
        return .{ .official = url, .fetch = url };
    }
    pub fn deinit(self: DownloadUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.official);
        if (self.official.ptr != self.fetch.ptr) {
            allocator.free(self.fetch);
        }
    }
};

const Release = struct {
    major: usize,
    minor: usize,
    patch: usize,
    pub fn order(a: Release, b: Release) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

// The Zig release where the OS-ARCH in the url was swapped to ARCH-OS
const arch_os_swap_release: Release = .{ .major = 0, .minor = 14, .patch = 1 };

fn makeOfficialUrl(arena: Allocator, semantic_version: SemanticVersion) DownloadUrl {
    return switch (determineVersionKind(semantic_version)) {
        .dev => DownloadUrl.initOfficial(std.fmt.allocPrint(
            arena,
            "https://ziglang.org/builds/zig-" ++ arch_os ++ "-{f}." ++ archive_ext,
            .{semantic_version},
        ) catch |e| oom(e)),
        .release => |release| DownloadUrl.initOfficial(std.fmt.allocPrint(
            arena,
            "https://ziglang.org/download/{0f}/zig-{1s}-{0f}." ++ archive_ext,
            .{
                semantic_version,
                switch (release.order(arch_os_swap_release)) {
                    .lt => os_arch,
                    .gt, .eq => arch_os,
                },
            },
        ) catch |e| oom(e)),
    };
}

fn getVersionUrl(
    arena: Allocator,
    environ: process.Environ,
    app_data_path: []const u8,
    semantic_version: SemanticVersion,
) !DownloadUrl {
    if (build_options.exe == .zls) return DownloadUrl.initOfficial(std.fmt.allocPrint(
        arena,
        "https://builds.zigtools.org/zls-{s}-{f}.{s}",
        .{ switch (determineVersionKind(semantic_version)) {
            .dev => arch_os,
            .release => |release| switch (release.order(arch_os_swap_release)) {
                .lt => os_arch,
                .gt, .eq => arch_os,
            },
        }, semantic_version, archive_ext },
    ) catch |e| oom(e));

    if (!isMachVersion(semantic_version)) return makeOfficialUrl(arena, semantic_version);

    const download_index_kind: DownloadIndexKind = .mach;
    const index_path = try Dir.path.join(arena, &.{ app_data_path, download_index_kind.basename() });
    defer arena.free(index_path);

    try_existing_index: {
        const index_content = Dir.cwd().readFileAlloc(io, index_path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => break :try_existing_index,
            else => |e| return pathErr("read", index_path, e),
        };
        defer arena.free(index_content);
        if (extractUrlFromMachDownloadIndex(arena, semantic_version, index_path, index_content)) |url|
            return url;
    }

    try fetchFile(arena, environ, app_data_path, download_index_kind.uri(), index_path);
    // since we just downloaded the file, this should always succeed now
    const index_content = try Dir.cwd().readFileAlloc(io, index_path, arena, .unlimited);
    defer arena.free(index_content);
    return extractUrlFromMachDownloadIndex(arena, semantic_version, index_path, index_content) orelse
        reportErr("compiler version '{f}' is missing from download index {s}", .{ semantic_version, index_path });
}

fn extractMasterVersion(
    scratch: std.mem.Allocator,
    index_filepath: []const u8,
    download_index: []const u8,
) SemanticVersion {
    const root = std.json.parseFromSlice(std.json.Value, scratch, download_index, .{
        .allocate = .alloc_if_needed,
    }) catch |e| std.debug.panic(
        "failed to parse download index '{s}' as JSON with {t}",
        .{ index_filepath, e },
    );
    defer root.deinit();
    const master_obj = root.value.object.get("master") orelse @panic(
        "download index is missing the 'master' version",
    );
    const version_val = master_obj.object.get("version") orelse errExit(
        "download index \"master\" object is missing the \"version\" property",
        .{},
    );
    return SemanticVersion.parse(version_val.string) orelse errExit(
        "unable to parse download index master version '{s}'",
        .{version_val.string},
    );
}

fn extractUrlFromMachDownloadIndex(
    allocator: std.mem.Allocator,
    semantic_version: SemanticVersion,
    index_filepath: []const u8,
    download_index: []const u8,
) ?DownloadUrl {
    const root = std.json.parseFromSlice(std.json.Value, allocator, download_index, .{
        .allocate = .alloc_if_needed,
    }) catch |e| std.debug.panic(
        "failed to parse download index '{s}' as JSON with {t}",
        .{ index_filepath, e },
    );
    defer root.deinit();
    const version_array = semantic_version.array();
    const version_str = version_array.slice();
    const version_obj = root.value.object.get(version_str) orelse return null;
    const arch_os_obj = version_obj.object.get(arch_os) orelse std.debug.panic(
        "compiler version '{s}' does not contain an entry for arch-os '{s}'",
        .{ version_str, arch_os },
    );
    const fetch_url = arch_os_obj.object.get("tarball") orelse std.debug.panic(
        "download index '{s}' version '{s}' arch-os '{s}' is missing the 'tarball' property",
        .{ index_filepath, version_str, arch_os },
    );
    const official_url = arch_os_obj.object.get("zigTarball") orelse std.debug.panic(
        "download index '{s}' version '{s}' arch-os '{s}' is missing the 'zigTarball' property",
        .{ index_filepath, version_str, arch_os },
    );
    return .{
        .fetch = allocator.dupe(u8, fetch_url.string) catch |e| oom(e),
        .official = allocator.dupe(u8, official_url.string) catch |e| oom(e),
    };
}

fn fetchFile(
    scratch: Allocator,
    environ: process.Environ,
    app_data_path: []const u8,
    uri: std.Uri,
    out_filepath: []const u8,
) !void {
    log.info("fetch '{f}' to '{s}'", .{ uri, out_filepath });
    const root = global.getRootProgressNode();

    const progress_node_name = std.fmt.allocPrint(scratch, "fetch {f}", .{uri}) catch |e| oom(e);
    defer scratch.free(progress_node_name);
    const node = root.start(progress_node_name, 1);
    defer node.end();

    var client: std.http.Client = .{ .allocator = scratch, .io = io };
    defer client.deinit();
    initProxies(&client, scratch, environ) catch |err| std.debug.panic(
        "fetch '{f}': init proxy failed with {t}",
        .{ uri, err },
    );

    // Each process downloads to its own temporary file which is then atomically renamed
    // over out_filepath (see TmpFile). If multiple processes fetch at the same time they
    // each download the file and the last rename wins.
    const tmp_path = Dir.path.join(scratch, &.{ app_data_path, "tmp" }) catch |e| oom(e);
    defer scratch.free(tmp_path);
    var tmp_file = try TmpFile.create(io, tmp_path);
    defer tmp_file.deinit(io);

    var req = client.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch |err| return reportErr("fetch '{f}' failed with {t}", .{ uri, err });
    defer req.deinit();
    req.sendBodiless() catch |err| switch (err) {
        error.WriteFailed => return reportErr(
            "fetch '{f}': sending the request failed with {t}",
            .{ uri, req.connection.?.stream_writer.err orelse err },
        ),
    };
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| switch (err) {
        error.WriteFailed => return reportErr(
            "fetch '{f}': sending the request failed with {t}",
            .{ uri, req.connection.?.stream_writer.err orelse err },
        ),
        error.ReadFailed => return reportErr(
            "fetch '{f}': receiving the response failed with {t}",
            .{ uri, req.connection.?.getReadError() orelse err },
        ),
        else => |e| return reportErr("fetch '{f}' failed with {t}", .{ uri, e }),
    };
    if (response.head.status != .ok) return reportErr(
        "fetch '{f}': HTTP response {} \"{s}\"",
        .{ uri, @backingInt(response.head.status), response.head.status.phrase() orelse "" },
    );
    if (response.head.content_encoding != .identity) return reportErr(
        "fetch '{f}': server sent {t} content, expected identity",
        .{ uri, response.head.content_encoding },
    );

    const content_length = response.head.content_length;

    var buf: [4096]u8 = undefined;
    var file_writer = tmp_file.file.writer(io, &buf);
    var transfer_buf: [64]u8 = undefined;
    const received = response.reader(&transfer_buf).streamRemaining(&file_writer.interface) catch |err| switch (err) {
        error.ReadFailed => {
            const read_err: anyerror = if (response.bodyErr()) |e| e else req.connection.?.getReadError() orelse err;
            return reportErr("fetch '{f}': receiving the response failed with {t}", .{ uri, read_err });
        },
        error.WriteFailed => return entryErr("write", tmp_path, &tmp_file.name, file_writer.err.?),
    };
    if (content_length) |expected| if (received != expected) return reportErr(
        "fetch '{f}': received {} of {} bytes",
        .{ uri, received, expected },
    );
    file_writer.interface.flush() catch return entryErr("write", tmp_path, &tmp_file.name, file_writer.err.?);

    try tmp_file.finish(io, out_filepath);
}

/// Fetch's "global cache" is dir_path (only used for zip temp files), not zig's. Recompressing
/// into it is disabled by zigroot/fetch.patch, it's a few times slower than the fetch itself.
fn cmdFetch(
    gpa: Allocator,
    arena: Allocator,
    environ: process.Environ,
    dir_path: []const u8,
    url: []const u8,
) !Package.Hash {
    const color: Color = .auto;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    try initProxies(&http_client, arena, environ);

    var directory: Directory = .{
        .handle = try Dir.cwd().createDirPathOpen(io, dir_path, .{}),
        .path = dir_path,
    };
    defer directory.handle.close(io);

    const local_storage: Package.Fetch.LocalStorage = .{
        // not used by Fetch
        .cache_root = .{ .root_dir = directory },
        .pkg_root = .{ .root_dir = directory },
    };

    var job_queue: Package.Fetch.JobQueue = .{
        .io = io,
        .http_client = &http_client,
        .global_cache = directory,
        .local_storage = &local_storage,
        .recursive = false,
        .read_only = false,
        .debug_hash = false,
        .mode = .all,
        .disable_recompress = true,
        .prog_node = global.getRootProgressNode(),
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .path_or_url = url },
        .location_tok = 0,
        .hash_tok = .none,
        .name_tok = 0,
        .lazy_status = .eager,
        .remote_package_root = undefined,
        .parent_package_root = .cwd(),
        .parent_manifest_ast = null,
        .prog_node = global.getRootProgressNode(),
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = undefined,
        .manifest_ast = undefined,
        .have_manifest = false,
        .computed_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .cli_module = null,
    };
    defer fetch.deinit();

    log.info("downloading '{s}'...", .{url});
    const failed = if (fetch.run()) false else |err| switch (err) {
        error.OutOfMemory => errExit("out of memory", .{}),
        error.Canceled => unreachable, // we never cancel
        error.FetchFailed => true, // error bundle checked below
    };
    // nothing should be running since recursive is false and recompression is disabled
    try job_queue.group.await(io);

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        try errors.renderToStderr(io, .{}, color);
        return error.Reported;
    }
    // the computed hash is undefined when the fetch failed
    if (failed) return reportErr("fetch of '{s}' failed without reporting an error", .{url});

    return fetch.computedPackageHash();
}

const BuildRoot = struct {
    directory: Cache.Directory,
    build_zig_basename: []const u8,
    cleanup_build_dir: ?Dir,

    fn deinit(br: *BuildRoot) void {
        if (br.cleanup_build_dir) |*dir| dir.close(io);
        br.* = undefined;
    }
};

const FindBuildRootOptions = struct {
    build_file: ?[]const u8 = null,
    cwd_path: ?[]const u8 = null,
};

fn findBuildRoot(arena: Allocator, options: FindBuildRootOptions) !?BuildRoot {
    const cwd_path = options.cwd_path orelse try process.currentPathAlloc(io, arena);
    const build_zig_basename = if (options.build_file) |bf|
        Dir.path.basename(bf)
    else
        std.zig.build_zig_basename;

    if (options.build_file) |bf| {
        if (Dir.path.dirname(bf)) |dirname| {
            const dir = Dir.cwd().openDir(io, dirname, .{}) catch |err| {
                errExit("unable to open directory to build file from argument 'build-file', '{s}': {t}", .{ dirname, err });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{ .path = dirname, .handle = dir },
                .cleanup_build_dir = dir,
            };
        }

        return .{
            .build_zig_basename = build_zig_basename,
            .directory = .{ .path = null, .handle = Dir.cwd() },
            .cleanup_build_dir = null,
        };
    }
    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        const joined_path = try Dir.path.join(arena, &[_][]const u8{ dirname, build_zig_basename });
        if (Dir.cwd().access(io, joined_path, .{})) |_| {
            const dir = Dir.cwd().openDir(io, dirname, .{ .iterate = true }) catch |err| {
                errExit("unable to open directory while searching for build.zig file, '{s}': {t}", .{ dirname, err });
            };

            if (try caseMatches(dir, build_zig_basename)) return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{
                    .path = dirname,
                    .handle = dir,
                },
                .cleanup_build_dir = dir,
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return pathErr("access", joined_path, e),
        }
        dirname = Dir.path.dirname(dirname) orelse return null;
    }
}

fn caseMatches(iterable_dir: Dir, name: []const u8) !bool {
    // TODO: maybe there is more efficient platform-specific mechanisms to implement this?
    var iterator = iterable_dir.iterate();
    var found_case_insensitive_match = false;
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
        found_case_insensitive_match = found_case_insensitive_match or std.ascii.eqlIgnoreCase(entry.name, name);
    }
    if (!found_case_insensitive_match) return error.FileNotFound;
    return false;
}

fn errExit(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    process.exit(1);
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
