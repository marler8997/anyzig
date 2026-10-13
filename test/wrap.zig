const builtin = @import("builtin");
const std = @import("std");
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);

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
    var concurrent: ?struct { count: u8, install: []const u8 } = null;
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
        expect_no_abandoned_installs or concurrent != null or default_verbosity)) std.debug.panic(
        "--corrupt-entry, --legacy-install, --expect-legacy-install, --uninstall, --remove-exe, --abandoned-installs, --lockless-installs, " ++
            "--expect-no-abandoned-installs, --concurrent and --default-verbosity require --appdata " ++
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
        if (default_verbosity) {
            Dir.cwd().deleteFile(io, anyzig_appdata ++ "/verbosity") catch |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            };
        } else {
            // the tests check anyzig's info logs, which the default verbosity hides
            try Dir.cwd().createDirPath(io, anyzig_appdata);
            try Dir.cwd().writeFile(io, .{ .sub_path = anyzig_appdata ++ "/verbosity", .data = "debug\n" });
        }
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
