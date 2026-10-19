const builtin = @import("builtin");
const std = @import("std");
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);

    // installed as a fake zig by --kill, blocks until stdin is closed
    if (all_args.len == 2 and std.mem.eql(u8, all_args[1], fake_zig_arg)) {
        var buf: [256]u8 = undefined;
        while (true) {
            _ = std.Io.File.stdin().readStreaming(io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => |e| return e,
            };
        }
    }

    // usage: wrap INPUT_DIR OUTPUT_DIR [SETUP_OPTIONS...] -- EXE ARGS...
    const input_dir = all_args[1];
    const output_dir = all_args[2];

    var isolate_appdata = false;
    var default_verbosity = false;
    var corrupt_entry: ?struct { content: []const u8, name: []const u8 } = null;
    var legacy_install: ?[]const u8 = null;
    var expect_legacy_install: ?[]const u8 = null;
    var uninstall: ?[]const u8 = null;
    var remove_exe: ?[]const u8 = null;
    var abandoned_installs: ?[]const u8 = null;
    var lockless_installs: ?[]const u8 = null;
    var expect_no_abandoned_installs = false;
    var offline = false;
    var kill = false;
    var concurrent: ?struct { count: u8, install: []const u8 } = null;
    var mirror: ?MirrorMode = null;
    var saved_mirrors: ?[]const u8 = null;
    var saved_index: ?[]const u8 = null;
    const exe_index = blk: {
        var i: usize = 3;
        while (i < all_args.len) : (i += 1) {
            const arg = all_args[i];
            if (std.mem.eql(u8, arg, "--")) break :blk i + 1;
            if (std.mem.eql(u8, arg, "--badhash")) {
                @panic("todo");
            } else if (std.mem.eql(u8, arg, "--appdata")) {
                isolate_appdata = true;
            } else if (std.mem.eql(u8, arg, "--default-verbosity")) {
                default_verbosity = true;
            } else if (std.mem.startsWith(u8, arg, "--corrupt-entry=")) {
                var it = std.mem.splitScalar(u8, arg["--corrupt-entry=".len..], ':');
                const content = it.next().?;
                corrupt_entry = .{ .content = content, .name = it.rest() };
            } else if (std.mem.startsWith(u8, arg, "--legacy-install=")) {
                legacy_install = arg["--legacy-install=".len..];
            } else if (std.mem.startsWith(u8, arg, "--expect-legacy-install=")) {
                expect_legacy_install = arg["--expect-legacy-install=".len..];
            } else if (std.mem.startsWith(u8, arg, "--abandoned-installs=")) {
                abandoned_installs = arg["--abandoned-installs=".len..];
            } else if (std.mem.startsWith(u8, arg, "--lockless-installs=")) {
                lockless_installs = arg["--lockless-installs=".len..];
            } else if (std.mem.eql(u8, arg, "--expect-no-abandoned-installs")) {
                expect_no_abandoned_installs = true;
            } else if (std.mem.startsWith(u8, arg, "--uninstall=")) {
                uninstall = arg["--uninstall=".len..];
            } else if (std.mem.startsWith(u8, arg, "--remove-exe=")) {
                remove_exe = arg["--remove-exe=".len..];
            } else if (std.mem.eql(u8, arg, "--offline")) {
                offline = true;
            } else if (std.mem.eql(u8, arg, "--kill")) {
                kill = true;
            } else if (std.mem.startsWith(u8, arg, "--mirror=")) {
                mirror = std.meta.stringToEnum(MirrorMode, arg["--mirror=".len..]) orelse
                    std.debug.panic("unknown mirror mode '{s}'", .{arg["--mirror=".len..]});
            } else if (std.mem.startsWith(u8, arg, "--saved-mirrors=")) {
                saved_mirrors = arg["--saved-mirrors=".len..];
            } else if (std.mem.startsWith(u8, arg, "--saved-index=")) {
                saved_index = arg["--saved-index=".len..];
            } else if (std.mem.startsWith(u8, arg, "--concurrent=")) {
                // COUNT:INSTALL, i.e. 2:zig-0.14.0
                var it = std.mem.splitScalar(u8, arg["--concurrent=".len..], ':');
                const count = try std.fmt.parseInt(u8, it.first(), 10);
                concurrent = .{ .count = count, .install = it.rest() };
            } else std.debug.panic("unknown setup option '{s}'", .{arg});
        }
        std.debug.panic("missing '--' before the exe", .{});
    };
    if (!isolate_appdata and (corrupt_entry != null or legacy_install != null or
        expect_legacy_install != null or uninstall != null or remove_exe != null or abandoned_installs != null or lockless_installs != null or
        expect_no_abandoned_installs or concurrent != null or default_verbosity or kill or mirror != null or saved_mirrors != null or saved_index != null)) std.debug.panic(
        "--corrupt-entry, --legacy-install, --expect-legacy-install, --uninstall, --remove-exe, --abandoned-installs, --lockless-installs, " ++
            "--expect-no-abandoned-installs, --concurrent, --default-verbosity, --kill, --mirror, --saved-mirrors and --saved-index require --appdata " ++
            "(we never modify or inspect the real appdata)",
        .{},
    );
    const anyzig_appdata = switch (builtin.os.tag) {
        .macos => "appdata/Library/Application Support/anyzig",
        else => "appdata/anyzig",
    };
    const hashstore_path = anyzig_appdata ++ "/hashstore";
    const installs_path = anyzig_appdata ++ "/zig";
    const legacy_cache_path = "legacy-cache";
    // anyzig doesn't verify the content of legacy installs, so any valid hash works
    const legacy_hash = "N-V-__8AANS1ihIOtIbwStI19vHd9274HDAeXLQjJFgZzdsY";
    const legacy_install_path = legacy_cache_path ++ "/p/" ++ legacy_hash;

    try Dir.cwd().deleteTree(io, output_dir);
    try Dir.cwd().createDir(io, output_dir, .default_dir);

    if (std.mem.eql(u8, input_dir, "--no-input")) {
        //
    } else {
        try copyDir(io, arena, input_dir, output_dir, input_dir, output_dir);
    }

    try std.process.setCurrentPath(io, output_dir);

    const env = init.environ_map;
    _ = env.swapRemove("ANYZIG_VERBOSE");
    if (offline) {
        // point the http proxies at a dead port so any attempt to use the network fails
        for ([_][]const u8{ "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }) |name| {
            try env.put(name, "http://127.0.0.1:1");
        }
    }
    if (isolate_appdata) {
        const appdata_root = try Dir.path.join(arena, &.{ try std.process.currentPathAlloc(io, arena), "appdata" });
        try env.put(switch (builtin.os.tag) {
            .windows => "LOCALAPPDATA",
            .macos => "HOME",
            else => "XDG_DATA_HOME",
        }, appdata_root);
        // anyzig looks for legacy installs in zig's global cache, keep it isolated too
        try env.put("ZIG_GLOBAL_CACHE_DIR", try Dir.path.join(arena, &.{
            try std.process.currentPathAlloc(io, arena),
            legacy_cache_path,
        }));
        // the tests check anyzig's info logs, which are hidden by default
        if (!default_verbosity) try env.put("ANYZIG_VERBOSE", "1");
    }
    if (legacy_install) |version| {
        const install_path = try Dir.path.join(arena, &.{ installs_path, version });
        try Dir.cwd().createDirPath(io, legacy_cache_path ++ "/p");
        try Dir.rename(.cwd(), install_path, .cwd(), legacy_install_path, io);
        try Dir.cwd().createDirPath(io, hashstore_path);
        var hashstore = try Dir.cwd().openDir(io, hashstore_path, .{});
        defer hashstore.close(io);
        try hashstore.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "zig-{s}", .{version}), .data = legacy_hash ++ "\n" });
    }
    if (expect_legacy_install) |version| {
        var content_buf: [legacy_hash.len + 1]u8 = undefined;
        const entry_path = try std.fmt.allocPrint(arena, hashstore_path ++ "/zig-{s}", .{version});
        const content = try Dir.cwd().readFile(io, entry_path, &content_buf);
        if (!std.mem.eql(u8, content, legacy_hash ++ "\n")) std.debug.panic(
            "hashstore entry '{s}' changed to '{s}'",
            .{ entry_path, content },
        );
        try Dir.cwd().access(io, legacy_install_path ++ "/zig" ++ comptime builtin.target.exeFileExt(), .{});
    }
    if (abandoned_installs) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |name| {
            const dir_path = try std.fmt.allocPrint(arena, anyzig_appdata ++ "/install/{s}", .{name});
            try Dir.cwd().createDirPath(io, dir_path);
            try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}.lock", .{dir_path}), .data = "" });
            try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/partial", .{dir_path}), .data = "" });
        }
    }
    if (lockless_installs) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |name| {
            const dir_path = try std.fmt.allocPrint(arena, anyzig_appdata ++ "/install/{s}", .{name});
            try Dir.cwd().createDirPath(io, dir_path);
            try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/partial", .{dir_path}), .data = "" });
        }
    }
    if (expect_no_abandoned_installs) {
        var dir = try Dir.cwd().openDir(io, anyzig_appdata ++ "/install", .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) std.debug.panic(
                "abandoned install '{s}/install/{s}' wasn't cleaned up",
                .{ anyzig_appdata, entry.name },
            );
        }
    }
    if (uninstall) |version| {
        const install_path = try Dir.path.join(arena, &.{ installs_path, version });
        try Dir.cwd().access(io, install_path, .{});
        try Dir.cwd().deleteTree(io, install_path);
    }
    if (remove_exe) |version| {
        const exe_path = try Dir.path.join(arena, &.{ installs_path, version, "zig" ++ comptime builtin.target.exeFileExt() });
        try Dir.cwd().deleteFile(io, exe_path);
    }
    if (saved_mirrors) |urls| {
        try Dir.cwd().createDirPath(io, anyzig_appdata);
        const content = try std.mem.replaceOwned(u8, arena, urls, ",", "\n");
        try Dir.cwd().writeFile(io, .{ .sub_path = anyzig_appdata ++ "/community-mirrors.txt", .data = content });
    }
    if (saved_index) |content| {
        try Dir.cwd().createDirPath(io, anyzig_appdata);
        try Dir.cwd().writeFile(io, .{ .sub_path = anyzig_appdata ++ "/download-index.json", .data = content });
    }
    if (corrupt_entry) |entry| {
        var hashstore = try Dir.cwd().openDir(io, hashstore_path, .{});
        defer hashstore.close(io);
        // the entry must already exist (i.e. from a previous test), otherwise we
        // wouldn't be testing a corrupt entry
        hashstore.access(io, entry.name, .{}) catch |err| std.debug.panic(
            "hashstore entry '{s}/{s}' to corrupt doesn't exist ({t})",
            .{ hashstore_path, entry.name, err },
        );
        const content: []const u8 = if (std.mem.eql(u8, entry.content, "empty"))
            ""
        else
            std.debug.panic("unknown corrupt entry content '{s}'", .{entry.content});
        try hashstore.writeFile(io, .{ .sub_path = entry.name, .data = content });
    }

    const argv = all_args[exe_index..];
    if (mirror) |mode| return runWithMirror(io, arena, argv, env, mode);
    if (kill) {
        if (builtin.os.tag != .windows) std.debug.panic(
            "--kill is only for windows, elsewhere anyzig execs zig so they're the same process",
            .{},
        );
        if (argv.len != 1) std.debug.panic("--kill takes no args after the exe, it runs the fake zig itself", .{});
        // a real zig would mean copying a whole install, ourselves as zig.exe is enough
        const fake_install_path = installs_path ++ "/" ++ fake_zig_version;
        try Dir.cwd().createDirPath(io, fake_install_path);
        const self_path = try std.process.executablePathAlloc(io, arena);
        try Dir.copyFile(.cwd(), self_path, .cwd(), fake_install_path ++ "/zig.exe", io, .{});
        return killAnyzig(io, &.{ argv[0], fake_zig_version, fake_zig_arg }, env);
    }
    if (concurrent) |c| {
        // holds the install's lock until every process waits on it, then exactly one must install
        var children: [16]std.process.Child = undefined;
        if (c.count < 2 or c.count > children.len) std.debug.panic("--concurrent count must be 2-{}", .{children.len});
        try Dir.cwd().createDirPath(io, anyzig_appdata ++ "/install");
        const lock_path = try std.fmt.allocPrint(arena, anyzig_appdata ++ "/install/{s}.lock", .{c.install});
        var lock_file: ?std.Io.File = try Dir.cwd().createFile(io, lock_path, .{ .truncate = false });
        defer if (lock_file) |f| f.close(io);
        try lock_file.?.lock(io, .exclusive);

        var stderr_paths: [children.len][]const u8 = undefined;
        for (children[0..c.count], stderr_paths[0..c.count], 0..) |*child, *stderr_path, i| {
            stderr_path.* = try std.fmt.allocPrint(arena, "stderr-{}", .{i});
            const stderr_file = try Dir.cwd().createFile(io, stderr_path.*, .{});
            defer stderr_file.close(io);
            child.* = try std.process.spawn(io, .{
                .argv = argv,
                .environ_map = env,
                .stderr = .{ .file = stderr_file },
            });
        }

        const waiting_msg = "waiting for another anyzig to finish installing";
        {
            const timeout_ms = 60_000;
            var elapsed_ms: u32 = 0;
            while (true) : (elapsed_ms += 10) {
                const waiting = for (stderr_paths[0..c.count]) |path| {
                    const content = try Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
                    if (std.mem.find(u8, content, waiting_msg) == null) break false;
                } else true;
                if (waiting) break;
                if (elapsed_ms >= timeout_ms) {
                    for (stderr_paths[0..c.count]) |path| {
                        const content = try Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
                        std.log.err("{s}:\n{s}", .{ path, content });
                    }
                    std.debug.panic("not every process logged '{s}' after {}ms", .{ waiting_msg, timeout_ms });
                }
                try io.sleep(.fromMilliseconds(10), .awake);
            }
        }
        // releases the lock
        lock_file.?.close(io);
        lock_file = null;

        var failed = false;
        for (children[0..c.count], 0..) |*child, i| {
            const term = try child.wait(io);
            if (!term.success()) {
                std.log.err("concurrent process {} {f}", .{ i, term });
                failed = true;
            }
        }
        var installed_count: usize = 0;
        for (stderr_paths[0..c.count]) |path| {
            const content = try Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
            // forwarded so the build step can check it
            try std.Io.File.stderr().writeStreamingAll(io, content);
            const install_msg = try std.fmt.allocPrint(arena, "{s} to '", .{c.install});
            if (std.mem.find(u8, content, install_msg) != null) {
                // "downloaded zig-0.14.0 to '...'" or "copied zig-0.14.0 to '...'"
                installed_count += 1;
            } else if (std.mem.find(u8, content, "was installed by another process") == null) {
                std.log.err("{s} neither installed {s} nor used another process's install", .{ path, c.install });
                failed = true;
            }
        }
        if (installed_count != 1) {
            std.log.err("expected exactly 1 process to install {s} but {} did", .{ c.install, installed_count });
            failed = true;
        }
        if (failed) return 0xff;
        try checkSingleInstall(io, installs_path);
        return 0;
    }
    if (builtin.os.tag == .windows) {
        var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env });
        switch (try child.wait(io)) {
            .exited => |code| return code,
            else => |term| {
                std.log.err("zig process {f}", .{term});
                return 0xff;
            },
        }
    } else {
        const err = std.process.replace(io, .{ .argv = argv, .environ_map = env });
        std.log.err("exec '{s}' failed with {t}", .{ argv[0], err });
        return 0xff;
    }
}

const MirrorMode = enum {
    /// responds 404 to everything
    @"not-found",
    /// serves a valid signature for another file (zig-x86_64-linux-0.14.1.tar.xz) and 404 for archives
    @"wrong-file",
    /// serves the signature for zig-x86_64-linux-0.14.1.tar.xz and an archive that doesn't match it
    @"bad-content",
};

// https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz.minisig
const zig_0_14_1_x86_64_linux_signature =
    "untrusted comment: signature from minisign secret key\n" ++
    "RUSGOq2NVecA2d2lir8hBZQBgqU4dezcQtz9T8Ss7rWcR7eGXze5FFz26g7rUlAkm2Sa+93+tsH8K5jQl4UaMZLEOLvsCetPsAo=\n" ++
    "trusted comment: timestamp:1748009016\tfile:zig-x86_64-linux-0.14.1.tar.xz\thashed\n" ++
    "VZx4p6rTfwd4qPZMPIstinMLfBRB/wLBWqJLGiYFrh+sXWlZ/XLmCVY1Uopb3sIGTDyBn/573CdkvAttWYlADQ==\n";

/// Runs anyzig with ANYZIG_MIRRORS set to two mirrors served by a fake mirror and ziglang.org
/// unreachable. Forwards anyzig's stderr followed by how many requests the mirror got, and
/// fails if anyzig leaked memory.
fn runWithMirror(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8, env: *std.process.Environ.Map, mode: MirrorMode) !u8 {
    const address: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    const port = server.socket.address.getPort();
    var request_count: std.atomic.Value(u32) = .init(0);
    (try std.Thread.spawn(.{}, serveMirror, .{ io, &server, mode, &request_count })).detach();

    try env.put("ANYZIG_MIRRORS", try std.fmt.allocPrint(arena, "http://127.0.0.1:{0}/a http://127.0.0.1:{0}/b", .{port}));
    // the fake mirror is http, only ziglang.org (https) goes to the dead proxy
    for ([_][]const u8{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" }) |name| _ = env.swapRemove(name);
    for ([_][]const u8{ "https_proxy", "HTTPS_PROXY" }) |name| try env.put(name, "http://127.0.0.1:1");

    const stderr_path = "stderr";
    const exit_code = blk: {
        const stderr_file = try Dir.cwd().createFile(io, stderr_path, .{});
        defer stderr_file.close(io);
        var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env, .stderr = .{ .file = stderr_file } });
        break :blk switch (try child.wait(io)) {
            .exited => |code| code,
            else => |term| std.debug.panic("anyzig {f}", .{term}),
        };
    };
    const stderr = try Dir.cwd().readFileAlloc(io, stderr_path, arena, .limited(1024 * 1024));
    try std.Io.File.stderr().writeStreamingAll(io, stderr);
    try std.Io.File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(
        arena,
        "fake mirror served {} requests\n",
        .{request_count.load(.monotonic)},
    ));
    if (std.mem.find(u8, stderr, "leaked") != null) {
        std.log.err("anyzig leaked memory", .{});
        return 0xff;
    }
    return exit_code;
}

fn serveMirror(io: std.Io, server: *std.Io.net.Server, mode: MirrorMode, request_count: *std.atomic.Value(u32)) void {
    while (true) {
        const stream = server.accept(io) catch |err| std.debug.panic("fake mirror accept failed with {t}", .{err});
        defer stream.close(io);
        var recv_buf: [8 * 1024]u8 = undefined;
        var send_buf: [8 * 1024]u8 = undefined;
        var reader = stream.reader(io, &recv_buf);
        var writer = stream.writer(io, &send_buf);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch |err| std.debug.panic("fake mirror receive failed with {t}", .{err});
        _ = request_count.fetchAdd(1, .monotonic);
        const target = request.head.target;
        const path = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
        const is_signature = std.mem.endsWith(u8, path, ".minisig");
        const content: ?[]const u8 = switch (mode) {
            .@"not-found" => null,
            .@"wrong-file" => if (is_signature) zig_0_14_1_x86_64_linux_signature else null,
            .@"bad-content" => if (is_signature) zig_0_14_1_x86_64_linux_signature else "not the signed archive",
        };
        const result = if (content) |c|
            request.respond(c, .{ .keep_alive = false })
        else
            request.respond("", .{ .status = .not_found, .keep_alive = false });
        result catch |err| std.debug.panic("fake mirror respond failed with {t}", .{err});
    }
}

/// The fake zig --kill installs, anyzig runs it with "anyzig 9.9.9 fake-zig-block-stdin"
/// (not a --option, anyzig expects a command after the version).
const fake_zig_version = "9.9.9";
const fake_zig_arg = "fake-zig-block-stdin";

/// Kills anyzig while the fake zig is running and fails unless it dies with anyzig. The fake
/// blocks reading stdin, which we keep open so it can't exit on its own. We don't use
/// Child.kill or wait until the end, they close stdin.
fn killAnyzig(io: std.Io, argv: []const []const u8, env: *std.process.Environ.Map) !u8 {
    const windows = std.os.windows;
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env, .stdin = .pipe });
    const anyzig_pid = win32.GetProcessId(child.id.?);

    // anyzig runs zig after it finds the install, find zig by its parent
    const zig_pid = blk: {
        const timeout_ms = 60_000;
        var elapsed_ms: u32 = 0;
        while (true) : (elapsed_ms += 10) {
            if (try findChildProcess(anyzig_pid)) |pid| break :blk pid;
            if (elapsed_ms >= timeout_ms) std.debug.panic("anyzig didn't start zig after {}ms", .{timeout_ms});
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    };
    const zig_process = win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_TERMINATE, .FALSE, zig_pid) orelse
        std.debug.panic("OpenProcess {} (zig) failed, error={t}", .{ zig_pid, windows.GetLastError() });
    defer windows.CloseHandle(zig_process);

    // zig must be blocked on stdin, otherwise it exiting proves nothing
    try io.sleep(.fromMilliseconds(500), .awake);
    if (win32.WaitForSingleObject(zig_process, 0) != win32.WAIT_TIMEOUT) {
        var code: u32 = undefined;
        _ = win32.GetExitCodeProcess(zig_process, &code);
        std.debug.panic("zig (pid {}) exited on its own with code {} before anyzig was killed", .{ zig_pid, code });
    }

    if (!win32.TerminateProcess(child.id.?, 1).toBool()) std.debug.panic(
        "TerminateProcess (anyzig) failed, error={t}",
        .{windows.GetLastError()},
    );
    // not child.wait yet, it closes stdin
    if (win32.WaitForSingleObject(child.id.?, win32.INFINITE) != win32.WAIT_OBJECT_0) std.debug.panic(
        "WaitForSingleObject (anyzig) failed, error={t}",
        .{windows.GetLastError()},
    );
    defer _ = child.wait(io) catch {};

    const timeout_ms = 10_000;
    switch (win32.WaitForSingleObject(zig_process, timeout_ms)) {
        win32.WAIT_OBJECT_0 => {
            std.log.info("zig (pid {}) died with anyzig (pid {})", .{ zig_pid, anyzig_pid });
            return 0;
        },
        win32.WAIT_TIMEOUT => {
            _ = win32.TerminateProcess(zig_process, 1);
            std.log.err("zig (pid {}) was still running {}ms after anyzig (pid {}) was killed", .{ zig_pid, timeout_ms, anyzig_pid });
            return 0xff;
        },
        else => |result| std.debug.panic("WaitForSingleObject returned {}, error={t}", .{ result, windows.GetLastError() }),
    }
}

/// Returns the id of the zig.exe process whose parent is parent_pid. Matched by name too, a
/// console app started without a console (i.e. by zig build) gets a conhost.exe child.
fn findChildProcess(parent_pid: u32) !?u32 {
    const windows = std.os.windows;
    const snapshot = win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) std.debug.panic(
        "CreateToolhelp32Snapshot failed, error={t}",
        .{windows.GetLastError()},
    );
    defer windows.CloseHandle(snapshot);
    var entry: win32.PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(win32.PROCESSENTRY32W);
    var ok = win32.Process32FirstW(snapshot, &entry).toBool();
    while (ok) : (ok = win32.Process32NextW(snapshot, &entry).toBool()) {
        if (entry.th32ParentProcessID != parent_pid) continue;
        const name = std.mem.sliceTo(&entry.szExeFile, 0);
        std.log.info("anyzig (pid {}) child process {} '{f}'", .{ parent_pid, entry.th32ProcessID, std.unicode.fmtUtf16Le(name) });
        if (std.os.windows.eqlIgnoreCaseWtf16(name, std.unicode.utf8ToUtf16LeStringLiteral("zig.exe"))) return entry.th32ProcessID;
    }
    return null;
}

const win32 = struct {
    const windows = std.os.windows;
    extern "kernel32" fn GetProcessId(Process: windows.HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: windows.BOOL, dwProcessId: u32) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn Process32FirstW(hSnapshot: windows.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn Process32NextW(hSnapshot: windows.HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) windows.BOOL;

    const SYNCHRONIZE = 0x00100000;
    const PROCESS_TERMINATE = 0x0001;
    const TH32CS_SNAPPROCESS = 0x00000002;
    const WAIT_OBJECT_0 = 0;
    const WAIT_TIMEOUT = 0x102;
    const INFINITE = 0xffffffff;

    const PROCESSENTRY32W = extern struct {
        dwSize: u32,
        cntUsage: u32,
        th32ProcessID: u32,
        th32DefaultHeapID: usize,
        th32ModuleID: u32,
        cntThreads: u32,
        th32ParentProcessID: u32,
        pcPriClassBase: i32,
        dwFlags: u32,
        szExeFile: [260]u16,
    };
};

fn checkSingleInstall(io: std.Io, path: []const u8) !void {
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        std.log.info("{s}/{s} ({t})", .{ path, entry.name, entry.kind });
        if (entry.kind != .directory) {
            std.log.err("unexpected {t} '{s}/{s}'", .{ entry.kind, path, entry.name });
            return error.UnexpectedEntry;
        }
        count += 1;
    }
    if (count != 1) {
        std.log.err("expected 1 install in '{s}' but found {}", .{ path, count });
        return error.UnexpectedInstallCount;
    }
}

fn copyDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var in_dir = try Dir.cwd().openDir(io, in_path, .{ .iterate = true });
    defer in_dir.close(io);

    var it = in_dir.iterate();
    while (try it.next(io)) |entry| {
        const in_sub_path = try Dir.path.join(allocator, &.{ in_path, entry.name });
        defer allocator.free(in_sub_path);
        const out_sub_path = try Dir.path.join(allocator, &.{ out_path, entry.name });
        defer allocator.free(out_sub_path);
        switch (entry.kind) {
            .directory => {
                try Dir.cwd().createDir(io, out_sub_path, .default_dir);
                try copyDir(io, allocator, in_root, out_root, in_sub_path, out_sub_path);
            },
            .file => try Dir.copyFile(.cwd(), in_sub_path, .cwd(), out_sub_path, io, .{}),
            .sym_link => {
                var target_buf: [Dir.max_path_bytes]u8 = undefined;
                const in_target = target_buf[0..try Dir.cwd().readLink(io, in_sub_path, &target_buf)];
                var out_target_buf: [Dir.max_path_bytes]u8 = undefined;
                const out_target = blk: {
                    if (Dir.path.isAbsolute(in_target)) {
                        if (!std.mem.startsWith(u8, in_target, in_root)) std.debug.panic(
                            "expected symlink target to start with '{s}' but got '{s}'",
                            .{ in_root, in_target },
                        );
                        break :blk try std.fmt.bufPrint(
                            &out_target_buf,
                            "{s}{s}",
                            .{ out_root, in_target[in_root.len..] },
                        );
                    }
                    break :blk in_target;
                };

                if (builtin.os.tag == .windows) @panic(
                    "we got a symlink on windows?",
                ) else try Dir.cwd().symLink(io, out_target, out_sub_path, .{});
            },
            else => std.debug.panic("copy {s} ({t})", .{ in_sub_path, entry.kind }),
        }
    }
}
