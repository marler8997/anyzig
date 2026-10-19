//! Atomically writes files. Content is written to a uniquely named file in a temporary
//! directory, synced, then renamed over the destination. Readers only ever see the old
//! file or the complete new one, and concurrent writers race to see whose rename lands
//! last. Readers and writers of the destination never wait on each other.
//!
//! All temporary files live in a single directory so files left behind by a process that
//! died (or a power loss) can be found and cleaned up by a later process. To know whether
//! a temporary file is abandoned, each one is its own liveness lock: its owner holds an
//! exclusive lock on it until it has been renamed and closed. The OS releases the lock
//! when the owner dies, so any temporary file that can be locked has no owner and is
//! safe to delete. This lock is only ever tried (never waited on) and only by the
//! cleanup, it doesn't coordinate access to the destination.
//!
//! The temporary directory must be on the same filesystem as the destination.
const TmpFile = @This();

const random_bytes_len = 12;
pub const name_len = std.fs.base64_encoder.calcSize(random_bytes_len);

dir: std.Io.Dir,
name: [name_len]u8,
file: std.Io.File,
state: enum { open, finished },

pub fn create(io: std.Io, tmp_dir_path: []const u8) !TmpFile {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, tmp_dir_path, .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);
    try cleanAbandoned(io, dir, tmp_dir_path);
    while (true) {
        var random_bytes: [random_bytes_len]u8 = undefined;
        io.random(&random_bytes);
        var name: [name_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&name, &random_bytes);
        const file = dir.createFile(io, &name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        errdefer {
            // delete before closing so no other process can lock it in between
            dir.deleteFile(io, &name) catch {};
            file.close(io);
        }
        // There's a window between creating the file and locking it where another
        // process cleaning up abandoned files could lock it first. If that happens it
        // will delete it, so we abandon this one and try again with a new name.
        if (!try tryLock(io, file)) {
            file.close(io);
            continue;
        }
        if (try isDeleted(io, file)) {
            file.close(io);
            continue;
        }
        return .{ .dir = dir, .name = name, .file = file, .state = .open };
    }
}

/// Always call deinit, even after a successful finish. Deletes the temporary file if
/// finish wasn't called or failed.
pub fn deinit(self: *TmpFile, io: std.Io) void {
    switch (self.state) {
        .open => {
            // delete before closing so no other process can lock it in between
            self.dir.deleteFile(io, &self.name) catch {};
            self.file.close(io);
        },
        .finished => {},
    }
    self.dir.close(io);
    self.* = undefined;
}

/// Syncs the temporary file and renames it to `dest_path`, replacing it if it exists.
pub fn finish(self: *TmpFile, io: std.Io, dest_path: []const u8) !void {
    std.debug.assert(self.state == .open);
    // without this the rename can reach the disk before the content, leaving an
    // empty or zero-filled file after a power loss
    try self.file.sync(io);
    // we keep the file open (and locked) until after the rename, otherwise another
    // process could clean it up before we rename it
    try renameReplace(io, self.dir, &self.name, dest_path);
    self.file.close(io);
    self.state = .finished;
}

/// Replacing a file with rename on windows fails with AccessDenied if another process
/// has the destination open (i.e. a reader) or is renaming over it at the same time.
/// POSIX rename semantics avoid this, but zig only uses them when the compile target's
/// minimum windows version is at least win10_rs5 (1809), and even then only on
/// filesystems that support them (not FAT/exFAT or some network shares). Our release
/// builds target the default minimum (win10) to support all windows versions, so they
/// never use them and this retry is the normal path for replacing a file that's in use.
/// Since anyzig only ever holds these files open briefly, we treat AccessDenied as
/// transient on windows and retry for a bounded amount of time.
fn renameReplace(io: std.Io, tmp_dir: std.Io.Dir, tmp_name: []const u8, dest_path: []const u8) !void {
    if (builtin.os.tag != .windows) return std.Io.Dir.rename(tmp_dir, tmp_name, .cwd(), dest_path, io);

    var delay_ms: i64 = 1;
    var total_ms: i64 = 0;
    var retries: u32 = 0;
    while (true) {
        std.Io.Dir.rename(tmp_dir, tmp_name, .cwd(), dest_path, io) catch |err| switch (err) {
            error.AccessDenied => if (total_ms < 2000) {
                try io.sleep(.fromMilliseconds(delay_ms), .awake);
                total_ms += delay_ms;
                delay_ms = @min(delay_ms * 2, 100);
                retries += 1;
                continue;
            } else {
                std.log.err(
                    "replace '{s}' still failed with AccessDenied after {} retries ({}ms)",
                    .{ dest_path, retries, total_ms },
                );
                return err;
            },
            else => |e| return e,
        };
        // this is the only evidence the retry path runs, i.e. for verifying it on windows
        if (retries > 0) std.log.debug(
            "replaced '{s}' after {} retries ({}ms), it was in use",
            .{ dest_path, retries, total_ms },
        );
        return;
    }
}

/// Deletes every file in the temporary directory that isn't locked by its owner.
fn cleanAbandoned(io: std.Io, dir: std.Io.Dir, dir_path: []const u8) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // some filesystems don't report the kind (.unknown), those are handled below
        // since we'll fail to delete a directory
        if (entry.kind == .directory) {
            std.log.err(
                "unexpected {s} '{s}' in temporary directory '{s}'",
                .{ @tagName(entry.kind), entry.name, dir_path },
            );
            return error.UnexpectedTmpEntry;
        }
        const file = dir.openFile(io, entry.name, .{}) catch |err| switch (err) {
            // its owner finished or another process cleaned it up
            error.FileNotFound => continue,
            else => |e| return logTmpErr("open", dir_path, entry.name, e),
        };
        defer file.close(io);
        // locked means its owner is still alive
        const locked = tryLock(io, file) catch |e| return logTmpErr("lock", dir_path, entry.name, e);
        if (!locked) continue;
        std.log.debug("deleting abandoned temporary file '{s}{c}{s}'", .{ dir_path, std.Io.Dir.path.sep, entry.name });
        // delete while we still hold the lock so its owner (if it's in the window
        // between creating and locking it) will see it's been deleted
        dir.deleteFile(io, entry.name) catch |err| switch (err) {
            // another process cleaned it up
            error.FileNotFound => {},
            else => |e| return logTmpErr("delete", dir_path, entry.name, e),
        };
    }
}

/// An error here blocks every write until the user deals with the file, so make sure
/// they know which one it is.
fn logTmpErr(op: []const u8, dir_path: []const u8, name: []const u8, err: anytype) @TypeOf(err) {
    std.log.err(
        "{s} temporary file '{s}{c}{s}' failed with {s}",
        .{ op, dir_path, std.Io.Dir.path.sep, name, @errorName(err) },
    );
    return err;
}

/// On windows we lock a single byte far beyond the end of the file instead of using
/// std.Io.File.tryLock, which locks byte 0. Windows locks are mandatory, so locking real
/// content would make reads of the file fail in the brief window after we rename it
/// but before we close it.
const windows_lock_offset: windows.LARGE_INTEGER = std.math.maxInt(windows.LARGE_INTEGER) - 1;
const windows_lock_len: windows.LARGE_INTEGER = 1;

/// Tries to take an exclusive lock without blocking, returns false if another process
/// holds it. The lock is released when the file is closed (or the process dies).
pub fn tryLock(io: std.Io, file: std.Io.File) !bool {
    if (builtin.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        return switch (windows.ntdll.NtLockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &windows_lock_offset,
            &windows_lock_len,
            null,
            .TRUE, // fail immediately
            .TRUE, // exclusive
        )) {
            .SUCCESS => true,
            .LOCK_NOT_GRANTED => false,
            .INSUFFICIENT_RESOURCES => error.SystemResources,
            else => |status| windows.unexpectedStatus(status),
        };
    }
    return file.tryLock(io, .exclusive);
}

/// Returns true if the file has been deleted since we opened it.
fn isDeleted(io: std.Io, file: std.Io.File) !bool {
    if (builtin.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var info: windows.FILE.STANDARD_INFORMATION = undefined;
        const rc = windows.ntdll.NtQueryInformationFile(
            file.handle,
            &io_status_block,
            &info,
            @sizeOf(windows.FILE.STANDARD_INFORMATION),
            .Standard,
        );
        if (rc != .SUCCESS) return windows.unexpectedStatus(rc);
        return info.DeletePending.toBool() or info.NumberOfLinks == 0;
    }
    return (try file.stat(io)).nlink == 0;
}

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

test "cleanup deletes abandoned temporary files but not live ones" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    // a file that isn't locked simulates one left behind by a process that died
    try tmp.dir.writeFile(io, .{ .sub_path = "abandoned", .data = "" });
    // creating a TmpFile cleans up, it must delete the abandoned file
    var live = try create(io, tmp_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "abandoned", .{}));

    // creating another must leave the live (locked) one alone
    var second = try create(io, tmp_path);
    try tmp.dir.access(io, &live.name, .{});

    // deinit invalidates the TmpFile, so copy the names out first
    const second_name = second.name;
    second.deinit(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &second_name, .{}));
    const live_name = live.name;
    live.deinit(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &live_name, .{}));
}

test "finish replaces the destination and leaves nothing in the temporary directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const tmp_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "tmp" });
    defer std.testing.allocator.free(tmp_path);
    const dest_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "dest" });
    defer std.testing.allocator.free(dest_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "dest", .data = "old" });
    var tmp_file = try create(io, tmp_path);
    defer tmp_file.deinit(io);
    try tmp_file.file.writeStreamingAll(io, "new");
    try tmp_file.finish(io, dest_path);

    const content = try tmp.dir.readFileAlloc(io, "dest", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("new", content);
    var tmp_dir = try tmp.dir.openDir(io, "tmp", .{ .iterate = true });
    defer tmp_dir.close(io);
    var it = tmp_dir.iterate();
    try std.testing.expectEqual(null, try it.next(io));
}
