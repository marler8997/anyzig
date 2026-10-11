const builtin = @import("builtin");
const std = @import("std");

pub fn main() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);

    // usage: wrap INPUT_DIR OUTPUT_DIR [SETUP_OPTIONS...] -- EXE ARGS...
    const input_dir = all_args[1];
    const output_dir = all_args[2];

    var isolate_appdata = false;
    var corrupt_entry: ?struct { content: []const u8, name: []const u8 } = null;
    var old_lock_file: ?[]const u8 = null;
    var global_cache_dir: ?[]const u8 = null;
    var offline = false;
    const exe_index = blk: {
        var i: usize = 3;
        while (i < all_args.len) : (i += 1) {
            const arg = all_args[i];
            if (std.mem.eql(u8, arg, "--")) break :blk i + 1;
            if (std.mem.eql(u8, arg, "--badhash")) {
                @panic("todo");
            } else if (std.mem.eql(u8, arg, "--appdata")) {
                isolate_appdata = true;
            } else if (std.mem.startsWith(u8, arg, "--corrupt-entry=")) {
                var it = std.mem.splitScalar(u8, arg["--corrupt-entry=".len..], ':');
                const content = it.next().?;
                corrupt_entry = .{ .content = content, .name = it.rest() };
            } else if (std.mem.startsWith(u8, arg, "--old-lock-file=")) {
                old_lock_file = arg["--old-lock-file=".len..];
            } else if (std.mem.startsWith(u8, arg, "--global-cache-dir=")) {
                global_cache_dir = arg["--global-cache-dir=".len..];
            } else if (std.mem.eql(u8, arg, "--offline")) {
                offline = true;
            } else std.debug.panic("unknown setup option '{s}'", .{arg});
        }
        std.debug.panic("missing '--' before the exe", .{});
    };
    if ((corrupt_entry != null or old_lock_file != null) and !isolate_appdata) std.debug.panic(
        "--corrupt-entry and --old-lock-file require --appdata (we never modify the real appdata)",
        .{},
    );
    const hashstore_path = switch (builtin.os.tag) {
        .macos => "appdata/Library/Application Support/anyzig/hashstore",
        else => "appdata/anyzig/hashstore",
    };

    try std.fs.cwd().deleteTree(output_dir);
    try std.fs.cwd().makeDir(output_dir);

    if (std.mem.eql(u8, input_dir, "--no-input")) {
        //
    } else {
        try copyDir(arena, input_dir, output_dir, input_dir, output_dir);
    }

    try std.posix.chdirZ(output_dir);

    var env = try std.process.getEnvMap(arena);
    // on Windows, fail if anyzig can't exec zig in-process (instead of spawning it)
    if (builtin.os.tag == .windows) try env.put("ANYZIG_TEST_REQUIRE_EXEC", "1");
    if (global_cache_dir) |dir| try env.put("ZIG_GLOBAL_CACHE_DIR", dir);
    if (offline) {
        // point the http proxies at a dead port so any attempt to use the network fails
        for ([_][]const u8{ "http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" }) |name| {
            try env.put(name, "http://127.0.0.1:1");
        }
    }
    if (isolate_appdata) {
        const appdata_root = try std.fs.path.join(arena, &.{ try std.process.getCwdAlloc(arena), "appdata" });
        try env.put(switch (builtin.os.tag) {
            .windows => "LOCALAPPDATA",
            .macos => "HOME",
            else => "XDG_DATA_HOME",
        }, appdata_root);
    }
    if (old_lock_file) |name| {
        // simulates a lock file left behind by an older version of anyzig
        var hashstore = try std.fs.cwd().openDir(hashstore_path, .{});
        defer hashstore.close();
        try hashstore.writeFile(.{ .sub_path = name, .data = "" });
    }
    if (corrupt_entry) |entry| {
        var hashstore = try std.fs.cwd().openDir(hashstore_path, .{});
        defer hashstore.close();
        // the entry must already exist (i.e. from a previous test), otherwise we
        // wouldn't be testing a corrupt entry
        hashstore.access(entry.name, .{}) catch |err| std.debug.panic(
            "hashstore entry '{s}/{s}' to corrupt doesn't exist ({s})",
            .{ hashstore_path, entry.name, @errorName(err) },
        );
        const content: []const u8 = if (std.mem.eql(u8, entry.content, "empty"))
            ""
        else if (std.mem.eql(u8, entry.content, "too_big"))
            &([1]u8{'a'} ** 4096)
        else
            std.debug.panic("unknown corrupt entry content '{s}'", .{entry.content});
        try hashstore.writeFile(.{ .sub_path = entry.name, .data = content });
    }

    if (builtin.os.tag == .windows) {
        var child: std.process.Child = .init(all_args[exe_index..], arena);
        child.env_map = &env;
        try child.spawn();
        const result = try child.wait();
        switch (result) {
            .Exited => |code| return code,
            inline else => |sig, tag| {
                std.log.err("zig process terminated from {s} with {}", .{ @tagName(tag), sig });
                return 0xff;
            },
        }
    } else {
        const exe = std.os.argv[exe_index];
        const envp = try std.process.createEnvironFromMap(arena, &env, .{});
        const err = std.posix.execveZ(
            exe,
            @ptrCast(std.os.argv.ptr + exe_index),
            envp,
        );
        std.log.err("exec '{s}' failed with {s}", .{ exe, @errorName(err) });
        return 0xff;
    }
}

fn copyDir(
    allocator: std.mem.Allocator,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var in_dir = try std.fs.cwd().openDir(in_path, .{ .iterate = true });
    defer in_dir.close();

    var it = in_dir.iterate();
    while (try it.next()) |entry| {
        const in_sub_path = try std.fs.path.join(allocator, &.{ in_path, entry.name });
        defer allocator.free(in_sub_path);
        const out_sub_path = try std.fs.path.join(allocator, &.{ out_path, entry.name });
        defer allocator.free(out_sub_path);
        switch (entry.kind) {
            .directory => {
                try std.fs.cwd().makeDir(out_sub_path);
                try copyDir(allocator, in_root, out_root, in_sub_path, out_sub_path);
            },
            .file => try std.fs.cwd().copyFile(in_sub_path, std.fs.cwd(), out_sub_path, .{}),
            .sym_link => {
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const in_target = try std.fs.cwd().readLink(in_sub_path, &target_buf);
                var out_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const out_target = blk: {
                    if (std.fs.path.isAbsolute(in_target)) {
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
                ) else try std.posix.symlink(out_target, out_sub_path);
            },
            else => std.debug.panic("copy {}", .{entry}),
        }
    }
}
