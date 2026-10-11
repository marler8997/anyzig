//! compare LAUNCHER EXE ARGS...
//!
//! Runs `EXE ARGS...` directly and `LAUNCHER EXE ARGS...`, and fails unless both
//! produce identical stdout, stderr and exit status.
const std = @import("std");

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    if (args.len < 3) {
        std.log.err("usage: compare LAUNCHER EXE ARGS...", .{});
        return 0xff;
    }
    const direct = try run(arena, args[2..]);
    const exec = try run(arena, args[1..]);
    if (direct.stdout.len == 0) {
        std.log.err("'{s}' printed nothing to stdout, nothing to compare", .{args[2]});
        return 1;
    }
    var ok = true;
    if (direct.term != exec.term) {
        std.log.err("exit code differs: direct 0x{x} exec 0x{x}", .{ direct.term, exec.term });
        ok = false;
    }
    inline for (.{ "stdout", "stderr" }) |stream| {
        const d = @field(direct, stream);
        const e = @field(exec, stream);
        if (!std.mem.eql(u8, d, e)) {
            std.log.err("{s} differs\n--- direct ---\n{s}\n--- exec ---\n{s}\n---", .{ stream, d, e });
            ok = false;
        }
    }
    return if (ok) 0 else 1;
}

const Result = struct {
    /// the full exit code (std.process.Child truncates it to a u8)
    term: u32,
    stdout: []const u8,
    stderr: []const u8,
};

fn run(arena: std.mem.Allocator, argv: []const []const u8) !Result {
    const windows = std.os.windows;
    var child = std.process.Child.init(argv, arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout: std.ArrayListUnmanaged(u8) = .{};
    var stderr: std.ArrayListUnmanaged(u8) = .{};
    try child.collectOutput(arena, &stdout, &stderr, 10 * 1024 * 1024);
    try windows.WaitForSingleObjectEx(child.id, windows.INFINITE, false);
    var code: windows.DWORD = undefined;
    if (windows.kernel32.GetExitCodeProcess(child.id, &code) == 0) return error.GetExitCodeProcessFailed;
    _ = try child.wait();
    return .{ .term = code, .stdout = stdout.items, .stderr = stderr.items };
}
