/// Creates the file or opens it if it already exists. The file must never be deleted.
///
/// On macOS, when multiple processes (or threads) open the same nonexistent file with
/// O_CREAT (and not O_EXCL) at once, some fail with ENOENT. With O_EXCL exactly one creates
/// it and the others get EEXIST, then open the existing file without O_CREAT.
pub fn createOrOpen(io: std.Io, dir: std.Io.Dir, name: []const u8) std.Io.File.OpenError!std.Io.File {
    if (dir.createFile(io, name, .{ .exclusive = true })) |file| {
        return file;
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    }
    return dir.openFile(io, name, .{});
}

const std = @import("std");

test "concurrent createOrOpen of the same new file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const thread_count = 8;
    const iterations = 500;
    const Shared = struct {
        dir: std.Io.Dir,
        arrived: std.atomic.Value(u32) = .init(0),
        failures: std.atomic.Value(u32) = .init(0),

        // every thread opens each name at the same time so their opens race
        fn run(shared: *@This()) void {
            for (0..iterations) |i| {
                _ = shared.arrived.fetchAdd(1, .acq_rel);
                while (shared.arrived.load(.acquire) < (i + 1) * thread_count) std.atomic.spinLoopHint();
                var name_buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "{}.lock", .{i}) catch unreachable;
                if (createOrOpen(std.testing.io, shared.dir, name)) |file| {
                    file.close(std.testing.io);
                } else |err| {
                    std.log.err("createOrOpen '{s}' failed with {t}", .{ name, err });
                    _ = shared.failures.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var shared: Shared = .{ .dir = tmp.dir };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(0, shared.failures.load(.monotonic));
}
