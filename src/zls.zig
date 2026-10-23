//! zls versions don't follow zig's, so unlike zig the zls to use for a zig version is selected
//! by zigtools (and can change over time). The selection is saved for each zig version and kept
//! until 'zls update'.

const std = @import("std");
const builtin = @import("builtin");

const main = @import("main.zig");

/// zigtools names builds by zig's arch names except arm
const arch_os = if (builtin.cpu.arch == .arm) "arm" ++ main.arch_os["armv7a".len..] else main.arch_os;
const select_version_url = "https://releases.zigtools.org/v1/zls/select-version";
/// The zls version used for each zig version, i.e. "zls-version/0.15.2" has "0.15.1".
const versions_basename = "zls-version";

const Selection = struct { version: main.SemanticVersion, url: []const u8 };

/// zls versions don't follow zig's (i.e. zig 0.15.2 uses zls 0.15.1) so zigtools selects a
/// compatible one. Its selection changes over time (i.e. a new zls patch release), so the zls
/// version is saved the first time and kept until 'zls update'.
pub fn findOrInstall(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    app_data: [:0]const u8,
    zig_version: main.SemanticVersion,
) ![:0]const u8 {
    if (try readVersion(arena, app_data, zig_version)) |zls_version| {
        if (try main.isInstalled(arena, app_data, &zls_version)) {
            std.log.debug("zig {f} uses zls {f}", .{ zig_version, zls_version });
            return main.installedExePath(arena, app_data, &zls_version);
        }
        std.log.debug("zls {f} for zig {f} isn't installed, selecting a zls again", .{ zls_version, zig_version });
    }
    const selection = try select(arena, environ, app_data, zig_version);
    std.log.info("zig {f} uses zls {f}", .{ zig_version, selection.version });
    const exe = try main.installIfMissing(gpa, arena, environ, app_data, &selection.version, selection.url);
    try writeVersion(arena, app_data, zig_version, selection.version);
    return exe;
}

/// 'zls update', checks for a newer zls than the one saved for the zig version. The old zls
/// is kept, other zig versions can use it and an editor could be running it.
pub fn update(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    app_data: [:0]const u8,
    zig_version: main.SemanticVersion,
) !void {
    const old = try readVersion(arena, app_data, zig_version);
    const selection = try select(arena, environ, app_data, zig_version);
    if (old) |o| {
        if (o.eql(selection.version) and try main.isInstalled(arena, app_data, &o)) {
            std.log.info("zls {f} for zig {f} is up to date", .{ o, zig_version });
            return;
        }
    }
    _ = try main.installIfMissing(gpa, arena, environ, app_data, &selection.version, selection.url);
    try writeVersion(arena, app_data, zig_version, selection.version);
    if (old) |o| {
        if (!o.eql(selection.version)) {
            std.log.info("updated zls for zig {f} from {f} to {f}", .{ zig_version, o, selection.version });
            return;
        }
    }
    std.log.info("installed zls {f} for zig {f}", .{ selection.version, zig_version });
}

fn select(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    app_data: [:0]const u8,
    version: main.SemanticVersion,
) !Selection {
    const zig_version = if (!main.isMachVersion(version)) version else blk: {
        const entry = try main.machIndexEntry(arena, environ, app_data, version);
        const zig_version_val = entry.object.get("version") orelse return main.reportErr(
            "mach download index version '{f}' is missing the 'version' property, can't tell which zig it uses",
            .{version},
        );
        const zig_version = main.SemanticVersion.parse(zig_version_val.string) orelse return main.reportErr(
            "mach download index version '{f}' has invalid zig version '{s}'",
            .{ version, zig_version_val.string },
        );
        std.log.debug("mach {f} is zig {f}", .{ version, zig_version });
        break :blk zig_version;
    };
    const unavailable = switch (try querySelectVersion(arena, environ, app_data, zig_version)) {
        .selected => |s| return s,
        .unavailable => |u| u,
    };
    // zigtools has no zls builds for older dev cycles (i.e. 0.13), the cycle's release is the
    // closest (i.e. mach versions use dev builds of zig)
    if (unavailable.code == select_version_no_builds and main.determineVersionKind(zig_version) == .dev) {
        const release: main.SemanticVersion = .{
            .major = zig_version.major,
            .minor = zig_version.minor,
            .patch = zig_version.patch,
            .pre = null,
            .build = null,
        };
        switch (try querySelectVersion(arena, environ, app_data, release)) {
            .selected => |s| {
                std.log.warn("zigtools has no zls for zig {f} ({s}), using zls {f} from the {f} release", .{
                    zig_version, unavailable.message, s.version, release,
                });
                return s;
            },
            .unavailable => {},
        }
    }
    return main.reportErr("zigtools has no zls for zig {f}: {s}", .{ zig_version, unavailable.message });
}

/// the select-version code for "No builds for the X.Y release cycle are currently available"
const select_version_no_builds = 1;

const SelectVersionResult = union(enum) {
    selected: Selection,
    unavailable: struct { code: i64, message: []const u8 },
};

/// See https://github.com/zigtools/release-worker
fn querySelectVersion(
    arena: std.mem.Allocator,
    environ: std.process.Environ,
    app_data: [:0]const u8,
    zig_version: main.SemanticVersion,
) !SelectVersionResult {
    const version_array = zig_version.array();
    var query_version: std.ArrayList(u8) = .empty;
    for (version_array.slice()) |c| switch (c) {
        // a '+' in a query is a space
        '+' => query_version.appendSlice(arena, "%2B") catch |e| oom(e),
        else => query_version.append(arena, c) catch |e| oom(e),
    };
    const url = std.fmt.allocPrint(
        arena,
        select_version_url ++ "?zig_version={s}&compatibility=only-runtime",
        .{query_version.items},
    ) catch |e| oom(e);
    // saved per zig version so concurrent processes selecting for other versions don't
    // replace it before it's read
    const responses_path = std.Io.Dir.path.join(arena, &.{ app_data, "zls-select-version" }) catch |e| oom(e);
    std.Io.Dir.cwd().createDirPath(main.io, responses_path) catch |err| return main.pathErr("create directory", responses_path, err);
    const response_path = std.fmt.allocPrint(arena, "{s}" ++ std.Io.Dir.path.sep_str ++ "{f}.json", .{ responses_path, zig_version }) catch |e| oom(e);
    std.log.debug("selecting a zls for zig {f}", .{zig_version});
    // the version only has characters that are valid in a URL
    main.fetchFile(arena, environ, app_data, std.Uri.parse(url) catch unreachable, response_path, .err) catch |err| return switch (err) {
        error.ReportedFetchFailed, error.ReportedHttpNotFound => error.Reported,
        error.Reported => |e| e,
    };
    const content = std.Io.Dir.cwd().readFileAlloc(main.io, response_path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => |e| oom(e),
        else => |e| return main.pathErr("read", response_path, e),
    };
    const invalid = "zigtools sent an invalid zls selection for zig {f}, see '{s}'";
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{}) catch
        return main.reportErr(invalid, .{ zig_version, response_path });
    if (root != .object) return main.reportErr(invalid, .{ zig_version, response_path });
    if (root.object.get("code")) |code| {
        const message = root.object.get("message") orelse return main.reportErr(invalid, .{ zig_version, response_path });
        if (code != .integer or message != .string) return main.reportErr(invalid, .{ zig_version, response_path });
        return .{ .unavailable = .{ .code = code.integer, .message = message.string } };
    }
    const version_val = root.object.get("version") orelse return main.reportErr(invalid, .{ zig_version, response_path });
    if (version_val != .string) return main.reportErr(invalid, .{ zig_version, response_path });
    const zls_version = main.SemanticVersion.parse(version_val.string) orelse return main.reportErr(invalid, .{ zig_version, response_path });
    const build = root.object.get(arch_os) orelse return main.reportErr(
        "zls {f} (for zig {f}) has no build for " ++ arch_os,
        .{ zls_version, zig_version },
    );
    const tarball = if (build == .object) build.object.get("tarball") else null;
    if (tarball == null or tarball.? != .string) return main.reportErr(invalid, .{ zig_version, response_path });
    return .{ .selected = .{ .version = zls_version, .url = tarball.?.string } };
}

fn versionPath(arena: std.mem.Allocator, app_data: [:0]const u8, zig_version: main.SemanticVersion) []const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s}" ++ std.Io.Dir.path.sep_str ++ versions_basename ++ std.Io.Dir.path.sep_str ++ "{f}",
        .{ app_data, zig_version },
    ) catch |e| oom(e);
}

/// Returns the zls version saved for the zig version, or null if there isn't one.
fn readVersion(arena: std.mem.Allocator, app_data: [:0]const u8, zig_version: main.SemanticVersion) error{Reported}!?main.SemanticVersion {
    const path = versionPath(arena, app_data, zig_version);
    var content_buf: [main.SemanticVersion.max_string + 2]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(main.io, path, &content_buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return main.pathErr("read", path, e),
    };
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    return main.SemanticVersion.parse(trimmed) orelse {
        std.log.warn("ignoring '{s}', '{s}' isn't a zls version", .{ path, trimmed });
        return null;
    };
}

fn writeVersion(arena: std.mem.Allocator, app_data: [:0]const u8, zig_version: main.SemanticVersion, zls_version: main.SemanticVersion) error{Reported}!void {
    const path = versionPath(arena, app_data, zig_version);
    const dir = std.Io.Dir.path.dirname(path).?;
    std.Io.Dir.cwd().createDirPath(main.io, dir) catch |err| return main.pathErr("create directory", dir, err);
    const version_array = zls_version.array();
    try main.writeVersionFile(app_data, path, version_array.slice());
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
