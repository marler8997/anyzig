//! Older versions of anyzig (before zig 0.17) saved the package hash of each version they
//! installed in <appdata>/hashstore/<exe>-<version>, the hash is where that version is in
//! zig's global cache (p/<hash>). This is only read now, to copy those installs (see
//! findLegacyInstall in main.zig).

const builtin = @import("builtin");
const std = @import("std");
const zig = @import("zig");
const anyzig = @import("root");
const log = if (builtin.is_test) std.log else anyzig.log;

fn entryPath(
    buf: *[std.Io.Dir.max_path_bytes]u8,
    hashstore_path: []const u8,
    name: []const u8,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}" ++ std.Io.Dir.path.sep_str ++ "{s}",
        .{ hashstore_path, name },
    ) catch std.debug.panic("hashstore path '{s}' + '{s}' is too long", .{ hashstore_path, name });
}

pub const Entry = union(enum) {
    not_found,
    /// The entry exists but doesn't contain a valid hash, a warning with the reason has
    /// already been logged. Callers treat it as missing.
    invalid,
    found: zig.Package.Hash,
};

pub fn find(io: std.Io, hashstore_path: []const u8, name: []const u8) !Entry {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = entryPath(&path_buf, hashstore_path, name);

    // +1 so we can detect files that are too big, the extra 32 bytes allows for trailing whitespace
    var content_buf: [zig.Package.Hash.max_len + 32 + 1]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, path, &content_buf) catch |err| switch (err) {
        // NotDir: very old versions of anyzig had a hashstore file instead of a directory
        error.FileNotFound, error.NotDir => return .not_found,
        else => |e| {
            log.err("read '{s}' failed with {t}", .{ path, e });
            return error.Reported;
        },
    };
    const hash_bytes = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (content.len == content_buf.len or hash_bytes.len > zig.Package.Hash.max_len) {
        log.warn(
            "hashstore entry '{s}' is invalid (too big, max hash length is {}), ignoring it",
            .{ path, zig.Package.Hash.max_len },
        );
        return .invalid;
    }
    if (hash_bytes.len == 0) {
        log.warn(
            "hashstore entry '{s}' is invalid (empty), ignoring it",
            .{path},
        );
        return .invalid;
    }
    switch (zig.Package.Hash.validate(hash_bytes)) {
        .ok => {},
        else => |reason| {
            log.warn(
                "hashstore entry '{s}' is invalid ({t}), ignoring it",
                .{ path, reason },
            );
            return .invalid;
        },
    }
    return .{ .found = zig.Package.Hash.fromSlice(hash_bytes) };
}

test find {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hashstore_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(hashstore_path);

    const hash = "N-V-__8AANS1ihIOtIbwStI19vHd9274HDAeXLQjJFgZzdsY";
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-0.14.0", .data = hash ++ "\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-empty", .data = " \n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-too-big", .data = &@as([zig.Package.Hash.max_len + 33]u8, @splat('a')) });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-bad", .data = "not-a-hash" });

    switch (try find(io, hashstore_path, "zig-0.14.0")) {
        .found => |found| try std.testing.expectEqualStrings(hash, found.toSlice()),
        else => |entry| return std.testing.expectEqual(.found, std.meta.activeTag(entry)),
    }
    try std.testing.expectEqual(.not_found, std.meta.activeTag(try find(io, hashstore_path, "zig-missing")));
    try std.testing.expectEqual(.invalid, std.meta.activeTag(try find(io, hashstore_path, "zig-empty")));
    try std.testing.expectEqual(.invalid, std.meta.activeTag(try find(io, hashstore_path, "zig-too-big")));
    try std.testing.expectEqual(.invalid, std.meta.activeTag(try find(io, hashstore_path, "zig-bad")));

    // a hashstore file instead of a directory
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ hashstore_path, "zig-0.14.0" });
    defer std.testing.allocator.free(file_path);
    try std.testing.expectEqual(.not_found, std.meta.activeTag(try find(io, file_path, "zig-0.14.0")));
}
