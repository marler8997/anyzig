pub const Verbosity = enum {
    debug,
    warn,
    pub const default: Verbosity = .warn;
};

pub const global = struct {
    pub var context: ?Context = null;
    var verbosity: std.atomic.Value(KnownVerbosity) = .init(.unknown);
    /// the thread that reads the verbosity file, 0 until one starts
    var reader: std.atomic.Value(std.Thread.Id) = .init(0);
};

const Context = struct {
    app_data: AppData,
    io: std.Io,

    fn showInfo(context: Context) bool {
        while (true) switch (global.verbosity.load(.acquire)) {
            .debug => return true,
            .warn => return false,
            .unknown => {
                const thread_id: std.Thread.Id = if (builtin.single_threaded) 1 else std.Thread.getCurrentId();
                if (global.reader.cmpxchgStrong(0, thread_id, .acquire, .acquire)) |reader| {
                    // reading the verbosity file logged, it can't wait for itself
                    if (reader == thread_id) return true;
                    context.io.futexWaitUncancelable(KnownVerbosity, &global.verbosity.raw, .unknown);
                    continue;
                }
                const verbosity: Verbosity = switch (readVerbosityFile(context.io, context.app_data)) {
                    .no_file => .default,
                    .loaded_from_file => |v| v,
                };
                global.verbosity.store(switch (verbosity) {
                    .debug => .debug,
                    .warn => .warn,
                }, .release);
                context.io.futexWake(KnownVerbosity, &global.verbosity.raw, std.math.maxInt(u32));
                return verbosity == .debug;
            },
        };
    }
};

const KnownVerbosity = enum(u32) {
    unknown,
    debug,
    warn,
};

pub fn readVerbosityFile(io: std.Io, app_data: AppData) union(enum) {
    no_file,
    loaded_from_file: Verbosity,
} {
    const verbosity_path = app_data.verbosity_path;
    // not Dir.readFile, it reads until EOF, costing a second read syscall
    var file = Dir.cwd().openFile(io, verbosity_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .no_file,
        else => |e| std.debug.panic("open '{s}' failed with {t}", .{ verbosity_path, e }),
    };
    defer file.close(io);
    var content_buf: [100]u8 = undefined;
    const len = file.readPositional(io, &.{&content_buf}, 0) catch |e|
        std.debug.panic("read '{s}' failed with {t}", .{ verbosity_path, e });
    if (len == content_buf.len) std.debug.panic(
        "file '{s}' is too big (expected 'debug' or 'warn')",
        .{verbosity_path},
    );
    const content = content_buf[0..len];
    const content_trimmed = std.mem.trimEnd(u8, content, &std.ascii.whitespace);
    if (std.mem.eql(u8, content_trimmed, "debug")) return .{ .loaded_from_file = .debug };
    if (std.mem.eql(u8, content_trimmed, "warn")) return .{ .loaded_from_file = .warn };
    std.debug.panic(
        "file '{s}' had the following unexpected content:\n" ++
            "---\n{s}\n---\n" ++
            "we currently only expect the content to be 'debug' or 'warn'",
        .{ verbosity_path, content },
    );
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
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

    switch (level) {
        .err, .warn => {},
        .info, .debug => {
            const show = if (global.context) |context| context.showInfo() else switch (global.verbosity.load(.acquire)) {
                .debug => true,
                .warn => false,
                .unknown => Verbosity.default == .debug,
            };
            if (!show) return;
        },
    }

    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    w.print("anyzig" ++ scope_level ++ ": " ++ format ++ "\n", args) catch return;
    w.flush() catch return;
}

const builtin = @import("builtin");
const std = @import("std");
const Dir = std.Io.Dir;
const AppData = @import("AppData.zig");
