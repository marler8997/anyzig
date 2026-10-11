//! Verifies anyzig's hot path stays fast. The hot path is a cache hit, i.e. `zig version`
//! in a project whose zig version is already installed, which is nearly every invocation.
//!
//! Wall time is too noisy to check on CI, so instead we check the things it's made of,
//! all of which are deterministic:
//!   - instruction count (measured with valgrind, not hardware counters, which CI
//!     machines usually don't expose)
//!   - syscall count
//!   - no syscalls that block or write (i.e. an fsync on every run used to cost ~5ms)
//! Budgets live in hotpath-budget.zon so any increase shows up in review.
//!
//! The fixture is a hashstore entry pointing at a fake package whose "zig" isn't
//! executable. anyzig does all its normal work, its execve fails, and it exits, so
//! everything strace and valgrind see is anyzig itself (plus a small, constant error
//! path), without the real compiler mixed in and without the network.
//!
//! usage: hotpath ANYZIG_EXE WORK_DIR
const std = @import("std");

const Budget = struct {
    instructions: u64,
    syscalls: u32,
};
const budget: Budget = @import("hotpath-budget.zon");

/// Syscalls a cache hit must never make before exec'ing the real zig. Each one either
/// blocks or means the hot path is writing, coordinating or spawning, none of which a
/// cache hit needs to do.
const forbidden = [_][]const u8{
    "fsync",    "fdatasync", "sync",      "syncfs",          "sync_file_range",
    "flock",    "rename",    "renameat",  "renameat2",       "unlink",
    "unlinkat", "link",      "linkat",    "symlink",         "symlinkat",
    "truncate", "ftruncate", "nanosleep", "clock_nanosleep", "socket",
    "connect",  "clone",     "clone3",    "fork",            "vfork",
    "wait4",
};

const fake_hash = "N-V-__8AAhotpathcheckfakehash";

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len != 3) fatal("expected 2 cmdline args but got {}", .{args.len - 1});
    // anyzig runs in the fixture's project directory, so make our paths absolute
    const anyzig_exe = try std.fs.cwd().realpathAlloc(arena, args[1]);
    try std.fs.cwd().deleteTree(args[2]);
    var work = try std.fs.cwd().makeOpenPath(args[2], .{});
    const work_dir = try work.realpathAlloc(arena, ".");
    defer work.close();
    try work.makePath("project");
    try work.writeFile(.{ .sub_path = "project/build.zig", .data = "" });
    try work.writeFile(.{ .sub_path = "project/build.zig.zon", .data = ".{ .minimum_zig_version = \"0.14.0\" }\n" });
    try work.makePath("cache/p/" ++ fake_hash);
    // not executable, so anyzig's execve fails and it exits
    try work.writeFile(.{ .sub_path = "cache/p/" ++ fake_hash ++ "/zig", .data = "not an executable" });
    try work.makePath("appdata/anyzig/hashstore");
    try work.writeFile(.{ .sub_path = "appdata/anyzig/hashstore/zig-0.14.0", .data = fake_hash });

    const project_dir = try std.fs.path.join(arena, &.{ work_dir, "project" });
    var env = try std.process.getEnvMap(arena);
    try env.put("XDG_DATA_HOME", try std.fs.path.join(arena, &.{ work_dir, "appdata" }));
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(arena, &.{ work_dir, "cache" }));

    const strace_path = try std.fs.path.join(arena, &.{ work_dir, "strace.txt" });
    runToExec(arena, project_dir, &env, &.{ "strace", "-o", strace_path, anyzig_exe, "version" });
    const cachegrind_path = try std.fs.path.join(arena, &.{ work_dir, "cachegrind.out" });
    runToExec(arena, project_dir, &env, &.{
        "valgrind",
        "--tool=cachegrind",
        "--cache-sim=no",
        try std.fmt.allocPrint(arena, "--cachegrind-out-file={s}", .{cachegrind_path}),
        anyzig_exe,
        "version",
    });

    const strace = try std.fs.cwd().readFileAlloc(arena, strace_path, std.math.maxInt(usize));
    var syscalls: u32 = 0;
    var errors: u32 = 0;
    var reached_exec = false;
    var lines = std.mem.splitScalar(u8, strace, '\n');
    // the first line is the execve of anyzig itself
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) continue;
        const name = line[0 .. std.mem.indexOfScalar(u8, line, '(') orelse fatal("unexpected strace line: {s}", .{line})];
        if (std.mem.eql(u8, name, "execve")) {
            if (std.mem.indexOf(u8, line, fake_hash) == null) fatal("unexpected execve: {s}", .{line});
            reached_exec = true;
            break;
        }
        syscalls += 1;
        if (forbiddenReason(name, line)) |reason| {
            std.debug.print("error: forbidden syscall before exec ({s}): {s}\n", .{ reason, line });
            errors += 1;
        }
    }
    if (!reached_exec) fatal("execve of the fake zig not found in '{s}'", .{strace_path});

    const instructions = blk: {
        const cachegrind = try std.fs.cwd().readFileAlloc(arena, cachegrind_path, std.math.maxInt(usize));
        var it = std.mem.splitScalar(u8, cachegrind, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "summary: ")) {
                break :blk std.fmt.parseInt(u64, std.mem.trim(u8, line["summary: ".len..], " "), 10) catch
                    fatal("bad cachegrind summary line: {s}", .{line});
            }
        }
        fatal("no summary line in '{s}'", .{cachegrind_path});
    };

    errors += check("instructions before exec", instructions, budget.instructions);
    errors += check("syscalls before exec", syscalls, budget.syscalls);
    if (errors > 0) {
        std.debug.print("syscalls were recorded in '{s}'\n", .{strace_path});
        std.process.exit(1);
    }
}

/// Runs anyzig (under strace/valgrind) on the fixture and verifies it got all the way to
/// exec'ing the fake zig, otherwise we wouldn't be measuring the whole hot path.
fn runToExec(arena: std.mem.Allocator, cwd: []const u8, env: *const std.process.EnvMap, argv: []const []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = arena,
        .argv = argv,
        .cwd = cwd,
        .env_map = env,
    }) catch |err| switch (err) {
        error.FileNotFound => fatal("'{s}' not found, it's required for this check (i.e. apt install strace valgrind)", .{argv[0]}),
        else => fatal("run '{s}' failed with {s}", .{ argv[0], @errorName(err) }),
    };
    const expected = "/p/" ++ fake_hash ++ "/zig' failed with AccessDenied";
    const ok = switch (result.term) {
        .Exited => |code| code == 0xff,
        else => false,
    };
    if (!ok or std.mem.indexOf(u8, result.stderr, expected) == null) fatal(
        "expected anyzig to exit with 255 after failing to exec the fake zig, but got {}\n--- stderr ---\n{s}",
        .{ result.term, result.stderr },
    );
}

fn forbiddenReason(name: []const u8, line: []const u8) ?[]const u8 {
    for (forbidden) |f| {
        if (std.mem.eql(u8, name, f)) return "forbidden on the hot path";
    }
    if (std.mem.eql(u8, name, "openat") or std.mem.eql(u8, name, "open")) {
        for ([_][]const u8{ "O_CREAT", "O_TRUNC", "O_WRONLY", "O_RDWR" }) |flag| {
            if (std.mem.indexOf(u8, line, flag) != null) return "opens a file for writing";
        }
    }
    if (std.mem.eql(u8, name, "fcntl") and std.mem.indexOf(u8, line, "LK") != null) return "file lock";
    for ([_][]const u8{ "write", "pwrite64", "writev", "pwritev", "pwritev2" }) |w| {
        if (!std.mem.eql(u8, name, w)) continue;
        const fd = line[name.len + 1 ..];
        if (!std.mem.startsWith(u8, fd, "1,") and !std.mem.startsWith(u8, fd, "2,")) return "writes to something other than stdout/stderr";
    }
    return null;
}

fn check(what: []const u8, measured: u64, limit: u64) u32 {
    if (measured > limit) {
        std.debug.print(
            "error: {s}: {} is over the budget of {} (+{d:.1}%), if this is expected, raise it in test/hotpath-budget.zon\n",
            .{ what, measured, limit, pct(measured, limit) },
        );
        return 1;
    }
    std.debug.print("{s}: {} (budget {})\n", .{ what, measured, limit });
    if (@as(f64, @floatFromInt(measured)) < @as(f64, @floatFromInt(limit)) * 0.8) std.debug.print(
        "note: {s} is {d:.1}% under budget, consider lowering it in test/hotpath-budget.zon\n",
        .{ what, -pct(measured, limit) },
    );
    return 0;
}

fn pct(measured: u64, limit: u64) f64 {
    return (@as(f64, @floatFromInt(measured)) - @as(f64, @floatFromInt(limit))) * 100 / @as(f64, @floatFromInt(limit));
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
