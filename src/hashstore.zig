//! Hashstore entries are only ever replaced atomically (see TmpFile) so readers never
//! see a partially written file and concurrent writers just race to see whose rename
//! lands last. Reading an entry takes no lock.

const std = @import("std");
const zig = @import("zig");
const anyzig = @import("root");
const TmpFile = @import("TmpFile.zig");

pub fn init(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.NotDir => {
            try std.fs.cwd().deleteFile(path);
            try std.fs.cwd().makePath(path);
        },
        else => |e| return e,
    };
}

fn entryPath(
    buf: *[std.fs.max_path_bytes]u8,
    hashstore_path: []const u8,
    name: []const u8,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}" ++ std.fs.path.sep_str ++ "{s}",
        .{ hashstore_path, name },
    ) catch std.debug.panic("hashstore path '{s}' + '{s}' is too long", .{ hashstore_path, name });
}

pub const Entry = union(enum) {
    not_found,
    /// The entry exists but doesn't contain a valid hash, a warning with the reason has
    /// already been logged. Callers should treat it as missing, the entry is only a cache
    /// that can be rebuilt by fetching again (which verifies the hash), and save will
    /// atomically overwrite it. We don't delete it here, that would race with another
    /// process saving a valid entry at the same time.
    invalid,
    found: zig.Package.Hash,
};

pub fn find(hashstore_path: []const u8, name: []const u8) !Entry {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = entryPath(&path_buf, hashstore_path, name);

    // +1 so we can detect files that are too big, the extra 32 bytes allows for trailing whitespace
    var content_buf: [zig.Package.Hash.max_len + 32 + 1]u8 = undefined;
    const content = blk: {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .not_found,
            else => |e| return e,
        };
        defer file.close();
        break :blk content_buf[0..try file.readAll(&content_buf)];
    };
    const hash_bytes = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (content.len == content_buf.len or hash_bytes.len > zig.Package.Hash.max_len) {
        anyzig.log.warn(
            "hashstore entry '{s}' is invalid (too big, max hash length is {}), it will be overwritten when this version is fetched",
            .{ path, zig.Package.Hash.max_len },
        );
        // do not delete file, creates race
        return .invalid;
    }
    if (hash_bytes.len == 0) {
        anyzig.log.warn(
            "hashstore entry '{s}' is invalid (empty), it will be overwritten when this version is fetched",
            .{path},
        );
        // do not delete file, creates race
        return .invalid;
    }
    return .{ .found = zig.Package.Hash.fromSlice(hash_bytes) };
}

pub fn save(tmp_path: []const u8, hashstore_path: []const u8, name: []const u8, content: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = entryPath(&path_buf, hashstore_path, name);
    var tmp_file = try TmpFile.create(tmp_path);
    defer tmp_file.deinit();
    try tmp_file.file.writeAll(content);
    try tmp_file.finish(path);
}

const ReverseLookup = std.AutoHashMapUnmanaged(
    zig.Package.Hash,
    std.ArrayListUnmanaged(anyzig.SemanticVersion),
);
pub fn allocReverseLookup(
    hashstore_path: []const u8,
    allocator: std.mem.Allocator,
) !ReverseLookup {
    var dir = try std.fs.cwd().makeOpenPath(hashstore_path, .{ .iterate = true });
    defer dir.close();
    var map: ReverseLookup = .{};
    var it = dir.iterate();
    const prefix = anyzig.exe_str ++ "-";
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        // Older versions of anyzig (before Oct 2026) created a "<entry>.lock" file next to
        // each entry, deleting it when finished. If one of those processes died, its lock
        // file was left behind and nothing deletes it anymore, so we clean them up here.
        // This can be removed once enough time has passed that no one is upgrading from
        // those versions.
        if (std.mem.endsWith(u8, entry.name, ".lock")) {
            anyzig.log.info("deleting lock file '{s}' left by an older version of anyzig", .{entry.name});
            dir.deleteFile(entry.name) catch |err| switch (err) {
                // another process deleted it
                error.FileNotFound => {},
                else => |e| {
                    anyzig.log.err(
                        "delete '{s}{c}{s}' failed with {s}",
                        .{ hashstore_path, std.fs.path.sep, entry.name, @errorName(e) },
                    );
                    return e;
                },
            };
            continue;
        }
        const version_str = entry.name[prefix.len..];
        const entry_version = anyzig.SemanticVersion.parse(version_str) orelse std.debug.panic(
            "entry '{s}' contains an invalid version '{s}'",
            .{ entry.name, version_str },
        );
        const hash = switch (try find(hashstore_path, entry.name)) {
            .not_found => std.debug.panic(
                "hashstore entry '{s}' disappeared while iterating?",
                .{entry.name},
            ),
            .invalid => continue,
            .found => |hash| hash,
        };
        const map_entry = map.getOrPut(allocator, hash) catch |e| oom(e);
        if (!map_entry.found_existing) {
            map_entry.value_ptr.* = .{};
        }
        map_entry.value_ptr.append(allocator, entry_version) catch |e| oom(e);
    }
    return map;
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
