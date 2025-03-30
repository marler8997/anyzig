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

pub const std_options: std.Options = .{
    .logFn = anyzigLog,
};

const exe_str = @tagName(build_options.exe);

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

fn isMachVersion(version: []const u8) bool {
    return std.mem.endsWith(u8, version, "-mach");
}

fn determineZigVersion(arena: Allocator, build_root: BuildRoot) ![]const u8 {
    const zon = try loadBuildZigZon(arena, build_root) orelse {
        log.err("TODO: no build.zig.zon file, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };

    if (try extractMachZigVersion(zon)) |version_extent| {
        const version = zon[version_extent.start..version_extent.limit];
        if (!std.mem.endsWith(u8, version, "-mach")) {
            log.err("expected the .mach_zig_version value to end with '-mach' but got '{s}'", .{version});
            std.process.exit(0xff);
        }
        log.info(
            "zig mach version '{s}' pulled from '{}build.zig.zon'",
            .{ version, build_root.directory },
        );
        return try arena.dupe(u8, version);
    }

    const version_extent = try extractMinZigVersion(zon) orelse {
        log.err("TODO: build.zig.zon does not have a minimum_zig_version, maybe try determining zig version from build.zig?", .{});
        std.process.exit(0xff);
    };
    const minimum_zig_version = zon[version_extent.start..version_extent.limit];
    log.info(
        "zig version '{s}' pulled from '{}build.zig.zon'",
        .{ minimum_zig_version, build_root.directory },
    );
    return try arena.dupe(u8, minimum_zig_version);

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
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    defer arena.free(all_args);

    const argv_index: usize, const manual_version: ?[]const u8 = blk: {
        if (all_args.len >= 2 and isRelease(all_args[1])) break :blk .{ 2, all_args[1] };
        break :blk .{ 1, null };
    };

    const maybe_command: ?[]const u8 = if (argv_index >= all_args.len) null else all_args[argv_index];

    var version: []const u8, const is_init = blk: {
        if (maybe_command) |command| {
            if (std.mem.startsWith(u8, command, "-") and
                !std.mem.eql(u8, command, "-h") and
                !std.mem.eql(u8, command, "--help") and
                !std.mem.eql(u8, command, "--version"))
            {
                try std.io.getStdErr().writer().print(
                    "error: expected a command but got '{s}'\n",
                    .{command},
                );
                std.process.exit(0xff);
            }
            if (build_options.exe == .zig and (std.mem.eql(u8, command, "init") or std.mem.eql(u8, command, "init-exe") or std.mem.eql(u8, command, "init-lib"))) {
                if (manual_version) |version| break :blk .{ version, true };
                try std.io.getStdErr().writer().print(
                    "error: anyzig init requires a version, i.e. 'zig 0.13.0 {s}'\n",
                    .{command},
                );
                std.process.exit(0xff);
            }
        }
        if (manual_version) |version| break :blk .{ version, false };
        const build_root = try findBuildRoot(arena, .{}) orelse {
            try std.io.getStdErr().writeAll(
                "no build.zig to pull a zig version from, you can:\n" ++
                    "  1. run '" ++ exe_str ++ " VERSION' to specify a version\n" ++
                    "  2. run from a directory where a build.zig can be found\n",
            );
            std.process.exit(0xff);
        };
        break :blk .{ try determineZigVersion(arena, build_root), false };
    };

    if (build_options.exe == .zls) {
        var splits = std.mem.splitScalar(u8, version, '.');
        const major = splits.next().?;
        const minor = splits.next().?;
        version = try std.fmt.allocPrint(arena, "{s}.{s}.0", .{ major, minor });
    }

    const app_data_path = try std.fs.getAppDataDir(arena, "anyzig");
    defer arena.free(app_data_path);
    log.info("appdata '{s}'", .{app_data_path});

    const hashstore_path = try std.fs.path.join(arena, &.{ app_data_path, "hashstore" });
    // no need to free
    try hashstore.init(hashstore_path);

    const hashstore_name = std.fmt.allocPrint(arena, exe_str ++ "-{s}", .{version}) catch |e| oom(e);
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
                    "zig '{s}' already exists at '{}{s}'",
                    .{ version, global_cache_directory, hash.path() },
                );
                break :blk hash;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
        }

        const url = try getVersionUrl(arena, app_data_path, version, json_arch_os);
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
        for (all_args[argv_index..]) |arg| {
            try al.append(arena, arg);
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
        const build_root = try findBuildRoot(arena, .{}) orelse @panic("init did not create a build.zig file");
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
                \\    .minimum_zig_version = "{s}",
                \\}}
                \\
            , .{version});
            return;
        };
        const version_extent = try extractMinZigVersion(zon) orelse {
            if (!std.mem.startsWith(u8, zon, ".{")) @panic("zon file did not start with '.{'");
            if (zon.len < 2 or zon[2] != '\n') @panic("zon file not start with '.{\\n");
            const f = try std.fs.cwd().createFile("build.zig.zon", .{});
            defer f.close();
            try f.writer().writeAll(zon[0..3]);
            try f.writer().print("    .minimum_zig_version = \"{s}\",\n", .{version});
            try f.writer().writeAll(zon[3..]);
            return;
        };

        const generated_version = zon[version_extent.start..version_extent.limit];
        if (std.mem.eql(u8, generated_version, version))
            return;
        std.debug.panic(
            "zig init generated version '{s}' but expected '{s}'",
            .{ generated_version, version },
        );
    }

    if (!stay_alive) {
        const argv = blk: {
            var al: ArrayListUnmanaged(?[*:0]const u8) = .{};
            try al.append(arena, versioned_exe);
            for (std.os.argv[argv_index..]) |arg| {
                try al.append(arena, arg);
            }
            break :blk try al.toOwnedSliceSentinel(arena, null);
        };
        const err = std.posix.execveZ(versioned_exe, argv, @ptrCast(std.os.environ.ptr));
        log.err("exec '{s}' failed with {s}", .{ versioned_exe, @errorName(err) });
        process.exit(0xff);
    }
}

fn isRelease(str: []const u8) bool {
    return if (std.SemanticVersion.parse(str)) |_| true else |e| switch (e) {
        error.Overflow => false,
        error.InvalidVersion => false,
    };
}

const arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .powerpc64le => "powerpc64le",
    .riscv64 => "riscv64",
    .x86 => "x86",
    .x86_64 => "x86_64",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .linux => "linux",
    .macos => "macos",
    .windows => "windows",
    else => @compileError("Unsupported OS"),
};

const url_platform = os ++ "-" ++ arch;
const json_arch_os = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

const VersionKind = enum { release, dev };
fn determineVersionKind(version: []const u8) VersionKind {
    return if (std.mem.indexOfAny(u8, version, "-+")) |_| .dev else .release;
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

fn getVersionUrl(
    arena: Allocator,
    app_data_path: []const u8,
    version: []const u8,
    arch_os: []const u8,
) !DownloadUrl {
    if (build_options.exe == .zls) return DownloadUrl.initOfficial(std.fmt.allocPrint(
        arena,
        "https://builds.zigtools.org/zls-{s}-{s}.{s}",
        .{ url_platform, version, archive_ext },
    ) catch |e| oom(e));

    if (!isMachVersion(version)) return switch (determineVersionKind(version)) {
        .dev => DownloadUrl.initOfficial(try std.fmt.allocPrint(
            arena,
            "https://ziglang.org/builds/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext,
            .{version},
        )),
        .release => DownloadUrl.initOfficial(try std.fmt.allocPrint(
            arena,
            "https://ziglang.org/download/{s}/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext,
            .{version},
        )),
    };

    const download_index_kind: DownloadIndexKind = .mach;
    const basename = switch (download_index_kind) {
        .official => "download-index.json",
        .mach => "download-index-mach.json",
    };
    const index_path = try std.fs.path.join(arena, &.{ app_data_path, basename });
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
        if (extractUrlFromMachDownloadIndex(arena, version, arch_os, index_path, index_content)) |url|
            return url;
    }

    try downloadFile(arena, download_index_kind.url(), index_path);
    const index_content = blk: {
        // since we just downloaded the file, this should always succeed now
        const file = try std.fs.cwd().openFile(index_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
    };
    defer arena.free(index_content);
    return extractUrlFromMachDownloadIndex(arena, version, arch_os, index_path, index_content) orelse {
        fatal("compiler version '{s}' is missing from download index {s}", .{ version, index_path });
    };
}

fn extractUrlFromMachDownloadIndex(
    allocator: std.mem.Allocator,
    version: []const u8,
    arch_os: []const u8,
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
    const version_obj = root.value.object.get(version) orelse return null;
    const arch_os_obj = version_obj.object.get(arch_os) orelse std.debug.panic(
        "compiler version '{s}' does not contain an entry for arch-os '{s}'",
        .{ version, arch_os },
    );
    const fetch_url = arch_os_obj.object.get("tarball") orelse std.debug.panic(
        "download index '{s}' version '{s}' arch-os '{s}' is missing the 'tarball' property",
        .{ index_filepath, version, arch_os },
    );
    const official_url = arch_os_obj.object.get("zigTarball") orelse std.debug.panic(
        "download index '{s}' version '{s}' arch-os '{s}' is missing the 'zigTarball' property",
        .{ index_filepath, version, arch_os },
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

fn downloadFile(allocator: Allocator, url: []const u8, out_filepath: []const u8) !void {
    std.log.info("downloading '{s}' to '{s}'", .{ url, out_filepath });

    const lock_filepath = try std.mem.concat(allocator, u8, &.{ out_filepath, ".lock" });
    defer allocator.free(lock_filepath);

    var file_lock = try LockFile.lock(lock_filepath);
    defer file_lock.unlock();

    std.fs.cwd().deleteFile(out_filepath) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    const tmp_filepath = try std.mem.concat(allocator, u8, &.{ out_filepath, ".downloading" });
    defer allocator.free(tmp_filepath);
    std.fs.cwd().deleteFile(tmp_filepath) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };

    if (std.fs.path.dirname(tmp_filepath)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    const tmp_file = try std.fs.cwd().createFile(tmp_filepath, .{});
    defer tmp_file.close();
    switch (download(allocator, url, tmp_file.writer())) {
        .ok => try std.fs.cwd().rename(tmp_filepath, out_filepath),
        .err => |err| {
            std.log.err("could not download '{s}': {s}", .{ url, err });
            std.process.exit(0xff);
        },
    }
}

const DownloadResult = union(enum) {
    ok: void,
    err: []u8,
    pub fn deinit(self: DownloadResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| allocator.free(e),
        }
    }
};
fn download(allocator: Allocator, url: []const u8, writer: anytype) DownloadResult {
    const uri = std.Uri.parse(url) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "the URL is invalid ({s})",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to query the HTTP proxy settings with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    var header_buffer: [4096]u8 = undefined;
    var request = client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to connect to the HTTP server with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    defer request.deinit();

    request.send() catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to send the HTTP request with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };
    request.wait() catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to read the HTTP response headers with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    if (request.response.status != .ok) return .{ .err = std.fmt.allocPrint(
        allocator,
        "the HTTP server replied with unsuccessful response '{d} {s}'",
        .{ @intFromEnum(request.response.status), request.response.status.phrase() orelse "" },
    ) catch |e| oom(e) };

    // TODO: we take advantage of request.response.content_length

    var buf: [4096]u8 = undefined;
    while (true) {
        const len = request.reader().read(&buf) catch |err| return .{ .err = std.fmt.allocPrint(
            allocator,
            "failed to read the HTTP response body with {s}'",
            .{@errorName(err)},
        ) catch |e| oom(e) };
        if (len == 0)
            return .ok;
        writer.writeAll(buf[0..len]) catch |err| return .{ .err = std.fmt.allocPrint(
            allocator,
            "failed to write the HTTP response body with {s}'",
            .{@errorName(err)},
        ) catch |e| oom(e) };
    }
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

    var root_prog_node = std.Progress.start(.{
        .root_name = "Fetch",
    });
    defer root_prog_node.end();

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
        .prog_node = root_prog_node,
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
        error.OutOfMemory => fatal("out of memory", .{}),
        error.FetchFailed => {}, // error bundle checked below
    };

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    const package_hash = fetch.computedPackageHash();

    root_prog_node.end();
    root_prog_node = .{ .index = .none };

    return package_hash;
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
                fatal("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
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
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return .{
                .build_zig_basename = build_zig_basename,
                .directory = .{
                    .path = dirname,
                    .handle = dir,
                },
                .cleanup_build_dir = dir,
            };
        } else |err| switch (err) {
            error.FileNotFound => {
                dirname = fs.path.dirname(dirname) orelse return null;
                continue;
            },
            else => |e| return e,
        }
    }
}

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    process.exit(1);
}
pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
