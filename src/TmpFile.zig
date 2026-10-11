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

dir: std.fs.Dir,
name: [name_len]u8,
file: std.fs.File,
state: enum { open, finished },

pub fn create(tmp_dir_path: []const u8) !TmpFile {
    var dir = try std.fs.cwd().makeOpenPath(tmp_dir_path, .{ .iterate = true });
    errdefer dir.close();
    try cleanAbandoned(dir, tmp_dir_path);
    while (true) {
        var random_bytes: [random_bytes_len]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var name: [name_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&name, &random_bytes);
        const file = dir.createFile(&name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        errdefer {
            // delete before closing so no other process can lock it in between
            dir.deleteFile(&name) catch {};
            file.close();
        }
        // There's a window between creating the file and locking it where another
        // process cleaning up abandoned files could lock it first. If that happens it
        // will delete it, so we abandon this one and try again with a new name.
        if (!try tryLock(file)) {
            file.close();
            continue;
        }
        if (try isDeleted(file)) {
            file.close();
            continue;
        }
        return .{ .dir = dir, .name = name, .file = file, .state = .open };
    }
}

/// Always call deinit, even after a successful finish. Deletes the temporary file if
/// finish wasn't called or failed.
pub fn deinit(self: *TmpFile) void {
    switch (self.state) {
        .open => {
            // delete before closing so no other process can lock it in between
            self.dir.deleteFile(&self.name) catch {};
            self.file.close();
        },
        .finished => {},
    }
    self.dir.close();
    self.* = undefined;
}

/// Syncs the temporary file and renames it to `dest_path`, replacing it if it exists.
pub fn finish(self: *TmpFile, dest_path: []const u8) !void {
    std.debug.assert(self.state == .open);
    // without this the rename can reach the disk before the content, leaving an
    // empty or zero-filled file after a power loss
    try self.file.sync();
    // we keep the file open (and locked) until after the rename, otherwise another
    // process could clean it up before we rename it
    try renameReplace(self.dir, &self.name, dest_path);
    self.file.close();
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
fn renameReplace(tmp_dir: std.fs.Dir, tmp_name: []const u8, dest_path: []const u8) !void {
    if (builtin.os.tag != .windows) return std.fs.rename(tmp_dir, tmp_name, std.fs.cwd(), dest_path);

    var delay_ms: u64 = 1;
    var total_ms: u64 = 0;
    var retries: u32 = 0;
    while (true) {
        std.fs.rename(tmp_dir, tmp_name, std.fs.cwd(), dest_path) catch |err| switch (err) {
            error.AccessDenied => if (total_ms < 2000) {
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
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
        if (retries > 0) std.log.info(
            "replaced '{s}' after {} retries ({}ms), it was in use",
            .{ dest_path, retries, total_ms },
        );
        return;
    }
}

/// Deletes every file in the temporary directory that isn't locked by its owner.
fn cleanAbandoned(dir: std.fs.Dir, dir_path: []const u8) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        // some filesystems don't report the kind (.unknown), those are handled below
        // since we'll fail to delete a directory
        if (entry.kind == .directory) {
            std.log.err(
                "unexpected {s} '{s}' in temporary directory '{s}'",
                .{ @tagName(entry.kind), entry.name, dir_path },
            );
            return error.UnexpectedTmpEntry;
        }
        const file = dir.openFile(entry.name, .{}) catch |err| switch (err) {
            // its owner finished or another process cleaned it up
            error.FileNotFound => continue,
            else => |e| return logTmpErr("open", dir_path, entry.name, e),
        };
        defer file.close();
        // locked means its owner is still alive
        const locked = tryLock(file) catch |e| return logTmpErr("lock", dir_path, entry.name, e);
        if (!locked) continue;
        std.log.info("deleting abandoned temporary file '{s}{c}{s}'", .{ dir_path, std.fs.path.sep, entry.name });
        // delete while we still hold the lock so its owner (if it's in the window
        // between creating and locking it) will see it's been deleted
        dir.deleteFile(entry.name) catch |err| switch (err) {
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
        .{ op, dir_path, std.fs.path.sep, name, @errorName(err) },
    );
    return err;
}

/// On windows we lock a single byte far beyond the end of the file instead of using
/// std.fs.File.tryLock, which locks byte 0. Windows locks are mandatory, so locking real
/// content would make reads of the file fail in the brief window after we rename it
/// but before we close it.
const windows_lock_offset: windows.LARGE_INTEGER = std.math.maxInt(windows.LARGE_INTEGER) - 1;
const windows_lock_len: windows.LARGE_INTEGER = 1;

/// Tries to take an exclusive lock without blocking, returns false if another process
/// holds it. The lock is released when the file is closed (or the process dies).
pub fn tryLock(file: std.fs.File) !bool {
    if (builtin.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        windows.LockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &windows_lock_offset,
            &windows_lock_len,
            null,
            windows.TRUE, // fail immediately
            windows.TRUE, // exclusive
        ) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => |e| return e,
        };
        return true;
    }
    return file.tryLock(.exclusive);
}

/// Returns true if the file has been deleted since we opened it.
fn isDeleted(file: std.fs.File) !bool {
    if (builtin.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var info: windows.FILE_STANDARD_INFORMATION = undefined;
        const rc = windows.ntdll.NtQueryInformationFile(
            file.handle,
            &io_status_block,
            &info,
            @sizeOf(windows.FILE_STANDARD_INFORMATION),
            .FileStandardInformation,
        );
        if (rc != .SUCCESS) return windows.unexpectedStatus(rc);
        return info.DeletePending != windows.FALSE or info.NumberOfLinks == 0;
    }
    return (try std.posix.fstat(file.handle)).nlink == 0;
}

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

test "cleanup deletes abandoned temporary files but not live ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    // a file that isn't locked simulates one left behind by a process that died
    try tmp.dir.writeFile(.{ .sub_path = "abandoned", .data = "" });
    // creating a TmpFile cleans up, it must delete the abandoned file
    var live = try create(tmp_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("abandoned", .{}));

    // creating another must leave the live (locked) one alone
    var second = try create(tmp_path);
    try tmp.dir.access(&live.name, .{});

    // deinit invalidates the TmpFile, so copy the names out first
    const second_name = second.name;
    second.deinit();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(&second_name, .{}));
    const live_name = live.name;
    live.deinit();
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(&live_name, .{}));
}

test "finish replaces the destination and leaves nothing in the temporary directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ root, "tmp" });
    defer std.testing.allocator.free(tmp_path);
    const dest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dest" });
    defer std.testing.allocator.free(dest_path);

    try tmp.dir.writeFile(.{ .sub_path = "dest", .data = "old" });
    var tmp_file = try create(tmp_path);
    defer tmp_file.deinit();
    try tmp_file.file.writeAll("new");
    try tmp_file.finish(dest_path);

    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "dest", 100);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("new", content);
    var tmp_dir = try tmp.dir.openDir("tmp", .{ .iterate = true });
    defer tmp_dir.close();
    var it = tmp_dir.iterate();
    try std.testing.expectEqual(null, try it.next());
}
