const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const assert = std.debug.assert;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Color = std.zig.Color;
const ThreadPool = std.Thread.Pool;
const cleanExit = std.process.cleanExit;
const native_os = builtin.os.tag;
const Cache = std.Build.Cache;
const Directory = std.Build.Cache.Directory;
const EnvVar = std.zig.EnvVar;

const zig = @import("zig");

const Package = zig.Package;
const introspect = zig.introspect;

pub const log = std.log;

const hashstore = @import("hashstore.zig");
const LockFile = @import("LockFile.zig");
const Cmdline = @import("Cmdline.zig");

pub const std_options: std.Options = .{
    .logFn = anyzigLog,
};

pub const exe_str = @tagName(build_options.exe);

const Verbosity = enum {
    debug,
    warn,
    pub const default: Verbosity = .debug;
};

const global = struct {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const gpa = gpa_instance.allocator();
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_instance.allocator();

    var cached_verbosity: ?Verbosity = null;
    var cached_app_data_dir: ?union(enum) {
        ok: []const u8,
        err: anyerror,
    } = null;

    fn getAppDataDir() ![]const u8 {
        if (cached_app_data_dir == null) {
            cached_app_data_dir = if (std.fs.getAppDataDir(arena, "anyzig")) |dir|
                .{ .ok = dir }
            else |e|
                .{ .err = e };
        }
        return switch (cached_app_data_dir.?) {
            .ok => |d| d,
            .err => |e| e,
        };
    }

    var root_progress_node: ?std.Progress.Node = null;
    fn getRootProgressNode() std.Progress.Node {
        if (root_progress_node == null) {
            root_progress_node = std.Progress.start(.{ .root_name = "anyzig" });
        }
        return root_progress_node.?;
    }
};

fn readVerbosityFile() union(enum) {
    no_app_data_dir,
    no_file,
    loaded_from_file: Verbosity,
} {
    const app_data_dir = global.getAppDataDir() catch return .no_app_data_dir;
    const verbosity_path = std.fs.path.join(global.arena, &.{ app_data_dir, "verbosity" }) catch |e| oom(e);
    defer global.arena.free(verbosity_path);
    const content = read_file: {
        const file = std.fs.cwd().openFile(verbosity_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .no_file,
            else => |e| std.debug.panic("open '{s}' failed with {s}", .{ verbosity_path, @errorName(e) }),
        };
        defer file.close();
        break :read_file file.readToEndAlloc(global.arena, std.math.maxInt(usize)) catch |err| std.debug.panic(
            "read '{s}' failed with {s}",
            .{ verbosity_path, @errorName(err) },
        );
    };
    defer global.arena.free(content);
    const content_trimmed = std.mem.trimRight(u8, content, &std.ascii.whitespace);
    if (std.mem.eql(u8, content_trimmed, "debug")) return .{ .loaded_from_file = .debug };
    if (std.mem.eql(u8, content_trimmed, "warn")) return .{ .loaded_from_file = .warn };
    std.debug.panic(
        "file '{s}' had the following unexpected content:\n" ++
            "---\n{s}\n---\n" ++
            "we currently only expect the content to be 'debug' or 'warn'",
        .{ verbosity_path, content },
    );
}

fn anyzigLog(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_level = comptime (switch (scope) {
        .default => switch (level) {
            .info => "",
            inline else => ": " ++ level.asText(),
        },
        else => |s| "(" ++ @tagName(s) ++ "): " ++ level.asText(),
    });

    check_verbosity: {
        switch (level) {
            .err, .warn => break :check_verbosity,
            .info, .debug => {},
        }
        if (global.cached_verbosity == null) {
            global.cached_verbosity = switch (readVerbosityFile()) {
                .no_app_data_dir => .debug,
                .no_file => .default,
                .loaded_from_file => |v| v,
            };
        }
        switch (global.cached_verbosity.?) {
            .debug => {},
            .warn => return,
        }
    }

    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print("anyzig" ++ scope_level ++ ": " ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

const Extent = struct { start: usize, limit: usize };

fn extractMinZigVersion(zon: []const u8) !?Extent {
    return extractZigVersion(zon, ".minimum_zig_version");
}
fn extractMachZigVersion(zon: []const u8) !?Extent {
    return extractZigVersion(zon, ".mach_zig_version");
}
fn extractZigVersion(zon: []const u8, needle: []const u8) !?Extent {
    var offset: usize = 0;
    while (true) {
        offset = skipWhitespaceAndComments(zon, offset);
        const minimum_zig_version = std.mem.indexOfPos(u8, zon, offset, needle) orelse return null;
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
    const zon = build_root.directory.handle.openFile("build.zig.zon", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer zon.close();
    return try zon.readToEndAlloc(arena, std.math.maxInt(usize));
}

fn isMachVersion(v: SemanticVersion) bool {
    if (v.build == null) {
        if (v.pre) |pre| return std.mem.eql(u8, pre.slice(), "mach");
    }
    return false;
}

fn determineSemanticVersion(scratch: Allocator, build_root: BuildRoot) !SemanticVersion {
    const zon = try loadBuildZigZon(scratch, build_root) orelse {
        log.err("TODO: no build.zig.zon file, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };
    defer scratch.free(zon);

    if (try extractMachZigVersion(zon)) |version_extent| {
        const version = zon[version_extent.start..version_extent.limit];
        if (!std.mem.endsWith(u8, version, "-mach")) errExit(
            "expected the .mach_zig_version value to end with '-mach' but got '{s}'",
            .{version},
        );
        log.info(
            "zig mach version '{s}' pulled from '{}build.zig.zon'",
            .{ version, build_root.directory },
        );
        return SemanticVersion.parse(version) orelse errExit(
            "{}build.zig.zon has invalid .mach_zig_version \"{s}\"",
            .{ build_root.directory, version },
        );
    }

    const version_extent = try extractMinZigVersion(zon) orelse errExit(
        "build.zig.zon is missing minimum_zig_version, either add it or run '{s} VERSION' to specify a version",
        .{@tagName(build_options.exe)},
    );
    const minimum_zig_version = zon[version_extent.start..version_extent.limit];
    log.info(
        "zig version '{s}' pulled from '{}build.zig.zon'",
        .{ minimum_zig_version, build_root.directory },
    );
    return SemanticVersion.parse(minimum_zig_version) orelse errExit(
        "{}build.zig.zon has invalid .minimum_zig_version \"{s}\"",
        .{ build_root.directory, minimum_zig_version },
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

pub fn main() !void {
    defer if (global.root_progress_node) |n| {
        n.end();
    };

    defer _ = global.gpa_instance.deinit();
    const gpa = global.gpa;

    defer global.arena_instance.deinit();
    const arena = global.arena;

    const cmdline: Cmdline = try .alloc(arena);
    defer cmdline.free(arena);

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
                                if (index == cmdline.len()) break;
                                index += 1;
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
                try std.io.getStdErr().writer().print(
                    "error: expected a command but got '{s}'\n",
                    .{command},
                );
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
                try std.io.getStdErr().writer().print(
                    "error: anyzig init requires a version, i.e. 'zig 0.13.0 {s}'\n",
                    .{command},
                );
                std.process.exit(0xff);
            }
            if (std.mem.eql(u8, command, "any")) std.process.exit(try anyCommand(cmdline, cmdline_offset + 1));
        }
        if (manual_version) |version| break :blk .{ version, false };
        const build_root = try findBuildRoot(arena, build_root_options) orelse {
            try std.io.getStdErr().writeAll(
                "no build.zig to pull a zig version from, you can:\n" ++
                    "  1. run '" ++ exe_str ++ " VERSION' to specify a version\n" ++
                    "  2. run from a directory where a build.zig can be found\n",
            );
            std.process.exit(0xff);
        };
        break :blk .{ .{ .semantic = try determineSemanticVersion(arena, build_root) }, false };
    };

    const app_data_path = try std.fs.getAppDataDir(arena, "anyzig");
    defer arena.free(app_data_path);
    log.info("appdata '{s}'", .{app_data_path});

    const semantic_version = semantic_version: switch (version_specifier) {
        .semantic => |v| v,
        .master => {
            const download_index_kind: DownloadIndexKind = .official;
            const index_path = try std.fs.path.join(arena, &.{ app_data_path, download_index_kind.basename() });
            defer arena.free(index_path);
            try fetchFile(arena, download_index_kind.url(), download_index_kind.uri(), index_path);
            const index_content = blk: {
                // since we just downloaded the file, this should always succeed now
                const file = try std.fs.cwd().openFile(index_path, .{});
                defer file.close();
                break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
            };
            defer arena.free(index_content);
            break :semantic_version extractMasterVersion(arena, index_path, index_content);
        },
    };
    if (version_specifier == .master) {
        std.log.info("master is at {}", .{semantic_version});
    }

    const hashstore_path = try std.fs.path.join(arena, &.{ app_data_path, "hashstore" });
    // no need to free
    try hashstore.init(hashstore_path);

    const hashstore_name = std.fmt.allocPrint(arena, exe_str ++ "-{}", .{semantic_version}) catch |e| oom(e);
    // no need to free

    const maybe_hash = maybeHashAndPath(try hashstore.find(hashstore_path, hashstore_name));

    const override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);
    var global_cache_directory: Directory = l: {
        const p = override_global_cache_dir orelse try introspect.resolveGlobalCacheDir(arena);
        break :l .{
            .handle = try fs.cwd().makeOpenPath(p, .{}),
            .path = p,
        };
    };
    defer global_cache_directory.handle.close();

    const hash = blk: {
        if (maybe_hash) |hash| {
            if (global_cache_directory.handle.access(hash.path(), .{})) |_| {
                log.info(
                    "{s} '{}' already exists at '{}{s}'",
                    .{ @tagName(build_options.exe), semantic_version, global_cache_directory, hash.path() },
                );
                break :blk hash;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }

        const url = try getVersionUrl(arena, app_data_path, semantic_version);
        defer url.deinit(arena);
        const hash = hashAndPath(try cmdFetch(
            gpa,
            arena,
            global_cache_directory,
            url.fetch,
            .{ .debug_hash = false },
        ));
        log.info("downloaded {s} to '{}{s}'", .{ hashstore_name, global_cache_directory, hash.path() });
        if (maybe_hash) |*previous_hash| {
            if (previous_hash.val.eql(&hash.val)) {
                log.info("{s} was already in the hashstore as {s}", .{ hashstore_name, hash.val.toSlice() });
            } else {
                log.warn(
                    "{s} hash has changed!\nold:{s}\nnew:{s}\n",
                    .{ hashstore_name, previous_hash.val.toSlice(), hash.val.toSlice() },
                );
                try hashstore.delete(hashstore_path, hashstore_name);
                try hashstore.save(hashstore_path, hashstore_name, hash.val.toSlice());
            }
        } else {
            try hashstore.save(hashstore_path, hashstore_name, hash.val.toSlice());
        }
        break :blk hash;
    };

    const versioned_exe = try global_cache_directory.joinZ(arena, &.{ hash.path(), exe_str });
    defer arena.free(versioned_exe);

    const stay_alive = is_init or (builtin.os.tag == .windows);

    if (stay_alive) {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: if on windows, create a job so our child process gets killed if
        //       our process gets killed
        var al: ArrayListUnmanaged([]const u8) = .{};
        try al.append(arena, versioned_exe);
        for (cmdline_offset..cmdline.len()) |arg_index| {
            try al.append(arena, cmdline.arg(arg_index));
        }
        var child: std.process.Child = .init(al.items, arena);
        try child.spawn();
        const result = try child.wait();
        switch (result) {
            .Exited => |code| if (code != 0) std.process.exit(0xff),
            else => std.process.exit(0xff),
        }
    }

    if (is_init) {
        const build_root = try findBuildRoot(arena, build_root_options) orelse @panic("init did not create a build.zig file");
        log.info("{}{s}", .{ build_root.directory, build_root.build_zig_basename });
        const zon = try loadBuildZigZon(arena, build_root) orelse {
            const f = try std.fs.cwd().createFile("build.zig.zon", .{});
            defer f.close();
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: maybe don't use .name = placeholder?
            try f.writer().print(
                \\.{{
                \\    .name = "placeholder",
                \\    .version = "0.0.0",
                \\    .minimum_zig_version = "{}",
                \\}}
                \\
            , .{semantic_version});
            return;
        };
        const version_extent = try extractMinZigVersion(zon) orelse {
            if (!std.mem.startsWith(u8, zon, ".{")) @panic("zon file did not start with '.{'");
            if (zon.len < 2 or zon[2] != '\n') @panic("zon file not start with '.{\\n");
            const f = try std.fs.cwd().createFile("build.zig.zon", .{});
            defer f.close();
            try f.writer().writeAll(zon[0..3]);
            try f.writer().print("    .minimum_zig_version = \"{}\",\n", .{semantic_version});
            try f.writer().writeAll(zon[3..]);
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
            "zig init generated version '{}' but expected '{}'",
            .{ generated_version, semantic_version },
        );
    }

    if (!stay_alive) {
        const argv = blk: {
            var al: ArrayListUnmanaged(?[*:0]const u8) = .{};
            try al.append(arena, versioned_exe);
            for (std.os.argv[cmdline_offset..]) |arg| {
                try al.append(arena, arg);
            }
            break :blk try al.toOwnedSliceSentinel(arena, null);
        };
        const err = std.posix.execveZ(versioned_exe, argv, @ptrCast(std.os.environ.ptr));
        log.err("exec '{s}' failed with {s}", .{ versioned_exe, @errorName(err) });
        process.exit(0xff);
    }
}

fn anyCommandUsage() !u8 {
    try std.io.getStdErr().writer().print(
        "any" ++ @tagName(build_options.exe) ++ " {s} from https://github.com/marler8997/anyzig\n" ++
            "Here are the anyzig-specific subcommands:\n" ++
            "  zig any set-verbosity LEVEL    | sets the default system-wide verbosity\n" ++
            "                                 | accepts 'warn' or 'debug\n" ++
            "  zig any version                | print the version of anyzig to stdout\n" ++
            "  zig any list-installed         | list all versions of zig installed in the global cache\n",
        .{@embedFile("version")},
    );
    return 0xff;
}

fn anyCommand(cmdline: Cmdline, cmdline_offset: usize) !u8 {
    if (cmdline_offset == cmdline.len()) {
        std.process.exit(try anyCommandUsage());
    }
    const command = cmdline.arg(cmdline_offset);
    const arg_offset = cmdline_offset + 1;

    if (std.mem.eql(u8, command, "version")) {
        if (arg_offset < cmdline.len()) errExit("the 'version' subcommand does not take any cmdline args", .{});
        try std.io.getStdOut().writer().print("{s}\n", .{@embedFile("version")});
        return 0;
    } else if (std.mem.eql(u8, command, "set-verbosity")) {
        if (arg_offset >= cmdline.len()) errExit("missing VERBOSITY (either 'warn' or 'debug')", .{});
        if (arg_offset + 1 < cmdline.len()) errExit("too many cmdline args", .{});
        const level_str = cmdline.arg(arg_offset);
        const level: Verbosity = blk: {
            if (std.mem.eql(u8, level_str, "warn")) break :blk .warn;
            if (std.mem.eql(u8, level_str, "debug")) break :blk .debug;
            errExit("unknown VERBOSITY '{s}', expected 'warn' or 'debug'", .{level_str});
        };
        {
            const app_data_dir = try global.getAppDataDir();
            const verbosity_path = std.fs.path.join(
                global.arena,
                &.{ app_data_dir, "verbosity" },
            ) catch |e| oom(e);
            defer global.arena.free(verbosity_path);
            if (std.fs.path.dirname(verbosity_path)) |dir| {
                try std.fs.cwd().makePath(dir);
            }
            const file = try std.fs.cwd().createFile(verbosity_path, .{});
            defer file.close();
            try file.writer().print("{s}\n", .{level_str});
        }
        switch (readVerbosityFile()) {
            .no_app_data_dir => @panic("no app data dir?"),
            .no_file => @panic("no file after writing it?"),
            .loaded_from_file => |l| std.debug.assert(l == level),
        }
        return 0;
    } else if (std.mem.eql(u8, command, "list-installed")) {
        if (arg_offset < cmdline.len()) errExit("the 'list-installed' subcommand does not take any cmdline args", .{});
        try listInstalled();
        return 0;
    } else errExit("unknown zig any '{s}' command", .{command});
}

fn listInstalled() !void {
    const app_data_dir = try global.getAppDataDir();

    const hashstore_path = try std.fs.path.join(global.arena, &.{ app_data_dir, "hashstore" });
    // no need to free
    try hashstore.init(hashstore_path);
    const reverse_lookup = try hashstore.allocReverseLookup(hashstore_path, global.arena);

    const override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(global.arena);
    const global_cache_dir_path = override_global_cache_dir orelse try introspect.resolveGlobalCacheDir(global.arena);
    const p_path = std.fs.path.join(global.arena, &.{ global_cache_dir_path, "p" }) catch |e| oom(e);
    defer global.arena.free(p_path);

    var p_dir: Directory = .{
        .handle = try fs.cwd().makeOpenPath(p_path, .{ .iterate = true }),
        .path = p_path,
    };
    defer p_dir.handle.close();

    var it = p_dir.handle.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len > zig.Package.Hash.max_len) continue;

        const hash_from_cache = zig.Package.Hash.fromSlice(entry.name);
        if (reverse_lookup.get(hash_from_cache)) |versions| {
            for (versions.items) |version| {
                try listVersion(p_path, version, entry.name);
            }
            continue;
        }

        // right now all zig distributed archives don't include a build.zig.zon so they
        // should all start with this
        if (!std.mem.startsWith(u8, entry.name, "N-V-__8AA")) continue;

        const exe_path = try std.fs.path.join(global.arena, &.{
            p_path,
            entry.name,
            comptime exe_str ++ builtin.target.exeFileExt(),
        });
        std.fs.cwd().access(exe_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        var child = std.process.Child.init(&.{ exe_path, "version" }, global.arena);
        child.stdout_behavior = .Pipe;
        child.spawn() catch continue; // probably not a valid zig

        const child_stdout = try child.stdout.?.reader().readAllAlloc(global.arena, 100);
        defer global.arena.free(child_stdout);
        const result = try child.wait();
        if (result != .Exited or result.Exited != 0) {
            // must not be a zig
            continue;
        }
        const version_str = std.mem.trimRight(u8, child_stdout, "\r\n");
        const semantic_version = SemanticVersion.parse(version_str) orelse continue;
        const hashstore_name = std.fmt.allocPrint(global.arena, exe_str ++ "-{}", .{semantic_version}) catch |e| oom(e);
        defer global.arena.free(hashstore_name);
        const maybe_hash = maybeHashAndPath(try hashstore.find(hashstore_path, hashstore_name));
        if (maybe_hash) |*anyzig_store_hash| {
            if (!anyzig_store_hash.val.eql(&hash_from_cache)) {
                log.err(
                    "{s} hash differs!\nglobal-cache:{s}\nanyzig-store:{s}\n",
                    .{ hashstore_name, entry.name, anyzig_store_hash.val.toSlice() },
                );
                continue;
                // try hashstore.delete(hashstore_path, hashstore_name);
                // try hashstore.save(hashstore_path, hashstore_name, hash.val.toSlice());
            }
        } else {
            // TODO: should we just trust the hash is good?
            log.info("new hash added to anyzig store: {s}", .{entry.name});
            try hashstore.save(hashstore_path, hashstore_name, entry.name);
        }
        try listVersion(p_path, semantic_version, entry.name);
    }
}

fn listVersion(p_path: []const u8, version: SemanticVersion, hash: []const u8) !void {
    const stdout = io.getStdOut().writer();
    try stdout.print("{}\t{s}{s}{s}\n", .{ version, p_path, std.fs.path.sep_str, hash });
}

pub const SemanticVersion = struct {
    const max_pre = 50;
    const max_build = 50;
    const max_string = 50 + max_pre + max_build;

    major: usize,
    minor: usize,
    patch: usize,
    pre: ?std.BoundedArray(u8, max_pre),
    build: ?std.BoundedArray(u8, max_build),

    pub fn array(self: *const SemanticVersion) std.BoundedArray(u8, max_string) {
        var result: std.BoundedArray(u8, max_string) = undefined;
        const roundtrip = std.fmt.bufPrint(&result.buffer, "{}", .{self}) catch unreachable;
        result.len = roundtrip.len;
        return result;
    }

    pub fn parse(s: []const u8) ?SemanticVersion {
        const parsed = std.SemanticVersion.parse(s) catch |e| switch (e) {
            error.Overflow, error.InvalidVersion => return null,
        };
        std.debug.assert(s.len <= max_string);

        var result: SemanticVersion = .{
            .major = parsed.major,
            .minor = parsed.minor,
            .patch = parsed.patch,
            .pre = if (parsed.pre) |pre| std.BoundedArray(u8, max_pre).init(pre.len) catch |e| switch (e) {
                error.Overflow => std.debug.panic("semantic version pre '{s}' is too long (max is {})", .{ pre, max_pre }),
            } else null,
            .build = if (parsed.build) |build| std.BoundedArray(u8, max_build).init(build.len) catch |e| switch (e) {
                error.Overflow => std.debug.panic("semantic version build '{s}' is too long (max is {})", .{ build, max_build }),
            } else null,
        };
        if (parsed.pre) |pre| @memcpy(result.pre.?.slice(), pre);
        if (parsed.build) |build| @memcpy(result.build.?.slice(), build);

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
    pub fn format(
        self: SemanticVersion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try self.ref().format(fmt, options, writer);
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
const os = switch (builtin.os.tag) {
    .freebsd => "freebsd",
    .linux => "linux",
    .macos => "macos",
    .netbsd => "netbsd",
    .windows => "windows",
    else => @compileError("Unsupported OS"),
};

const os_arch = os ++ "-" ++ arch;
const arch_os = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

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
            .mach => "https://machengine.org/zig/index.json",
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
            "https://ziglang.org/builds/zig-" ++ arch_os ++ "-{0}." ++ archive_ext,
            .{semantic_version},
        ) catch |e| oom(e)),
        .release => |release| DownloadUrl.initOfficial(std.fmt.allocPrint(
            arena,
            "https://ziglang.org/download/{0}/zig-{1s}-{0}." ++ archive_ext,
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
    app_data_path: []const u8,
    semantic_version: SemanticVersion,
) !DownloadUrl {
    if (build_options.exe == .zls) return DownloadUrl.initOfficial(std.fmt.allocPrint(
        arena,
        "https://builds.zigtools.org/zls-{s}-{}.{s}",
        .{ os_arch, semantic_version, archive_ext },
    ) catch |e| oom(e));

    if (!isMachVersion(semantic_version)) return makeOfficialUrl(arena, semantic_version);

    const download_index_kind: DownloadIndexKind = .mach;
    const index_path = try std.fs.path.join(arena, &.{ app_data_path, download_index_kind.basename() });
    defer arena.free(index_path);

    try_existing_index: {
        const index_content = blk: {
            const file = std.fs.cwd().openFile(index_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :try_existing_index,
                else => |e| return e,
            };
            defer file.close();
            break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
        };
        defer arena.free(index_content);
        if (extractUrlFromMachDownloadIndex(arena, semantic_version, index_path, index_content)) |url|
            return url;
    }

    try fetchFile(arena, download_index_kind.url(), download_index_kind.uri(), index_path);
    const index_content = blk: {
        // since we just downloaded the file, this should always succeed now
        const file = try std.fs.cwd().openFile(index_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
    };
    defer arena.free(index_content);
    return extractUrlFromMachDownloadIndex(arena, semantic_version, index_path, index_content) orelse {
        errExit("compiler version '{}' is missing from download index {s}", .{ semantic_version, index_path });
    };
}

fn extractMasterVersion(
    scratch: std.mem.Allocator,
    index_filepath: []const u8,
    download_index: []const u8,
) SemanticVersion {
    const root = std.json.parseFromSlice(std.json.Value, scratch, download_index, .{
        .allocate = .alloc_if_needed,
    }) catch |e| std.debug.panic(
        "failed to parse download index '{s}' as JSON with {s}",
        .{ index_filepath, @errorName(e) },
    );
    defer root.deinit();
    const master_obj = root.value.object.get("master") orelse @panic(
        "download index is missing the 'master' version",
    );
    const version_val = master_obj.object.get("version") orelse errExit(
        "download index \"master\" object is is missing the \"version\" property",
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
        "failed to parse download index '{s}' as JSON with {s}",
        .{ index_filepath, @errorName(e) },
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

const PathBuf = std.BoundedArray(u8, 2 + zig.Package.Hash.max_len);
const HashAndPath = struct {
    val: zig.Package.Hash,
    path_buf: PathBuf,
    pub fn path(self: *const HashAndPath) []const u8 {
        return self.path_buf.slice();
    }
};
fn maybeHashAndPath(maybe_hash: ?zig.Package.Hash) ?HashAndPath {
    return hashAndPath(maybe_hash orelse return null);
}
fn hashAndPath(hash: zig.Package.Hash) HashAndPath {
    const hash_slice = hash.toSlice();
    var result: HashAndPath = .{
        .val = hash,
        .path_buf = PathBuf.init(2 + hash_slice.len) catch unreachable,
    };
    result.path_buf.buffer[0] = 'p';
    result.path_buf.buffer[1] = std.fs.path.sep;
    @memcpy(result.path_buf.buffer[2..][0..hash_slice.len], hash_slice);
    return result;
}

fn fetchFile(
    scratch: Allocator,
    url_string: []const u8,
    uri: std.Uri,
    out_filepath: []const u8,
) !void {
    log.info("fetch '{}' to '{s}'", .{ uri, out_filepath });
    const root = global.getRootProgressNode();

    const progress_node_name = std.fmt.allocPrint(scratch, "fetch {s}", .{uri}) catch |e| oom(e);
    defer scratch.free(progress_node_name);
    const node = root.start(progress_node_name, 1);
    defer node.end();

    const lock_filepath = try std.mem.concat(scratch, u8, &.{ out_filepath, ".lock" });
    defer scratch.free(lock_filepath);

    // TODO: might be nice for the lock file to report progress as well?
    var file_lock = try LockFile.lock(lock_filepath);
    defer file_lock.unlock();

    var client = std.http.Client{ .allocator = scratch };
    defer client.deinit();
    client.initDefaultProxies(scratch) catch |err| std.debug.panic(
        "fetch '{}': init proxy failed with {s}",
        .{ uri, @errorName(err) },
    );
    var header_buffer: [4096]u8 = undefined;
    var request = client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch |e| std.debug.panic(
        "fetch '{}': connect failed with {s}",
        .{ uri, @errorName(e) },
    );
    defer request.deinit();
    request.send() catch |e| std.debug.panic(
        "fetch '{}': send failed with {s}",
        .{ uri, @errorName(e) },
    );
    request.wait() catch |e| std.debug.panic(
        "fetch '{}': wait failed with {s}",
        .{ uri, @errorName(e) },
    );
    if (request.response.status != .ok) return errExit(
        "fetch '{}': HTTP response {} \"{?s}\"",
        .{ uri, @intFromEnum(request.response.status), request.response.status.phrase() },
    );

    const out_filepath_tmp = std.mem.concat(scratch, u8, &.{ out_filepath, ".fetching" }) catch |e| oom(e);
    defer scratch.free(out_filepath_tmp);

    const file = std.fs.cwd().createFile(out_filepath_tmp, .{}) catch |e| std.debug.panic(
        "create '{s}' failed with {s}",
        .{ out_filepath_tmp, @errorName(e) },
    );
    defer {
        if (std.fs.cwd().deleteFile(out_filepath_tmp)) {
            std.log.info("removed '{s}'", .{out_filepath_tmp});
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| std.log.err("remove '{s}' failed with {s}", .{ out_filepath_tmp, @errorName(e) }),
        }
        file.close();
    }

    const maybe_content_length: ?u64 = blk: {
        // content length doesn't seem to be working with the mach index?
        // not sure if it's a problem with the mach server or Zig's HTTP client
        if (request.response.content_length) |content_length| {
            if (std.mem.eql(u8, url_string, DownloadIndexKind.mach.url())) {
                std.log.warn("ignoring content length {} for mach index", .{content_length});
                break :blk null;
            }
        }
        break :blk request.response.content_length;
    };

    if (maybe_content_length) |content_length| {
        try file.setEndPos(content_length);
    }

    var total_received: u64 = 0;
    while (true) {
        var buf: [@max(std.heap.page_size_min, 4096)]u8 = undefined;
        const len = request.reader().read(&buf) catch |e| std.debug.panic(
            "fetch '{}': read failed with {s}",
            .{ uri, @errorName(e) },
        );
        if (len == 0) break;
        total_received += len;

        if (maybe_content_length) |content_length| {
            if (total_received > content_length) errExit(
                "fetch '{}': read more than Content-Length ({})",
                .{ uri, content_length },
            );
        }
        // NOTE: not going through a buffered writer since we're writing
        //       large chunks
        file.writer().writeAll(buf[0..len]) catch |err| std.debug.panic(
            "fetch '{}': write {} bytes of HTTP response failed with {s}",
            .{ uri, len, @errorName(err) },
        );
    }

    if (maybe_content_length) |content_length| {
        if (total_received != content_length) errExit(
            "fetch '{}': Content-Length is {} but only read {}",
            .{ uri, content_length, total_received },
        );
    }

    try std.fs.cwd().rename(out_filepath_tmp, out_filepath);
}

pub fn cmdFetch(
    gpa: Allocator,
    arena: Allocator,
    global_cache_directory: Directory,
    url: []const u8,
    opt: struct {
        debug_hash: bool,
    },
) !zig.Package.Hash {
    const color: Color = .auto;
    const work_around_btrfs_bug = native_os == .linux and
        EnvVar.ZIG_BTRFS_WORKAROUND.isSet();

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{ .allocator = gpa });
    defer thread_pool.deinit();

    var http_client: std.http.Client = .{ .allocator = gpa };
    defer http_client.deinit();

    try http_client.initDefaultProxies(arena);

    var job_queue: Package.Fetch.JobQueue = .{
        .http_client = &http_client,
        .thread_pool = &thread_pool,
        .global_cache = global_cache_directory,
        .recursive = false,
        .read_only = false,
        .debug_hash = opt.debug_hash,
        .work_around_btrfs_bug = work_around_btrfs_bug,
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .path_or_url = url },
        .location_tok = 0,
        .hash_tok = 0,
        .name_tok = 0,
        .lazy_status = .eager,
        .parent_package_root = undefined,
        .parent_manifest_ast = null,
        .prog_node = global.getRootProgressNode(),
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .allow_missing_fingerprint = true,
        .allow_name_string = true,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = null,
        .manifest_ast = undefined,
        .computed_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .module = null,
    };
    defer fetch.deinit();

    log.info("downloading '{s}'...", .{url});
    fetch.run() catch |err| switch (err) {
        error.OutOfMemory => errExit("out of memory", .{}),
        error.FetchFailed => {}, // error bundle checked below
    };

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    return fetch.computedPackageHash();
}

const BuildRoot = struct {
    directory: Cache.Directory,
    build_zig_basename: []const u8,
    cleanup_build_dir: ?fs.Dir,

    fn deinit(br: *BuildRoot) void {
        if (br.cleanup_build_dir) |*dir| dir.close();
        br.* = undefined;
    }
};

const FindBuildRootOptions = struct {
    build_file: ?[]const u8 = null,
    cwd_path: ?[]const u8 = null,
};

fn findBuildRoot(arena: Allocator, options: FindBuildRootOptions) !?BuildRoot {
    const cwd_path = options.cwd_path orelse try process.getCwdAlloc(arena);
    const build_zig_basename = if (options.build_file) |bf|
        fs.path.basename(bf)
    else
        Package.build_zig_basename;

    if (options.build_file) |bf| {
        if (fs.path.dirname(bf)) |dirname| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                errExit("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{ .path = dirname, .handle = dir },
                .cleanup_build_dir = dir,
            };
        }

        return .{
            .build_zig_basename = build_zig_basename,
            .directory = .{ .path = null, .handle = fs.cwd() },
            .cleanup_build_dir = null,
        };
    }
    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        const joined_path = try fs.path.join(arena, &[_][]const u8{ dirname, build_zig_basename });
        if (fs.cwd().access(joined_path, .{})) |_| {
            const dir = fs.cwd().openDir(dirname, .{ .iterate = true }) catch |err| {
                errExit("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
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
            else => |e| return e,
        }
        dirname = fs.path.dirname(dirname) orelse return null;
    }
}

fn caseMatches(iterable_dir: std.fs.Dir, name: []const u8) !bool {
    // TODO: maybe there is more efficient platform-specific mechanisms to implement this?
    var iterator = iterable_dir.iterate();
    var found_case_insensitive_match = false;
    while (try iterator.next()) |entry| {
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
pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
