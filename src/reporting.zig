const std = @import("std");

// the logging done in this struct is printed conditionally based on the verbosity level
pub const Reporter = struct {
    // this might be more useful to have as an enum of levels rather than bools like this
    verbose_enabled: bool = false,
    debug_enabled: bool = false,

    pub fn init(verbose_enabled: bool, debug_enabled: bool) Reporter {
        return .{
            .verbose_enabled = verbose_enabled,
            .debug_enabled = debug_enabled,
        };
    }

    pub fn info(self: *const Reporter, comptime format: []const u8, args: anytype) void {
        if (self.verbose_enabled) {
            logOutWithPrefix("anyzig.info: ", format, args);
        }
    }

    pub fn debug(self: *const Reporter, comptime format: []const u8, args: anytype) void {
        if (self.debug_enabled) {
            logOutWithPrefix("anyzig.debug: ", format, args);
        }
    }

    pub fn warn(self: *const Reporter, comptime format: []const u8, args: anytype) void {
        if (self.verbose_enabled or self.debug_enabled) {
            logErrWithPrefix("anyzig.warn: ", format, args);
        }
    }
};

// the most basic logging function, no prefix
//useful for printing menus and formatting
pub fn log(comptime format: []const u8, args: anytype) void {
    logOutWithPrefix("", format, args);
}

// throw error will exit the program with a default exit code
// it might be useful to make an error module to hold enums for error sets and codes
pub fn throwError(comptime format: []const u8, args: anytype) void {
    throwErrorWithExitCode(format, args, 0xff);
}

pub fn throwErrorWithExitCode(comptime format: []const u8, args: anytype, exit_code: u8) void {
    logErrWithPrefix("anyzig.error: ", format, args);
    std.process.exit(exit_code);
}

// panic uses zig's standard panic function
pub fn panic(comptime format: []const u8, args: anytype) void {
    std.debug.panic("anyzig.panic: " ++ format ++ "\n", args);
}

// used when a warning should be shown regardless of verbosity
pub fn criticalWarn(comptime format: []const u8, args: anytype) void {
    logErrWithPrefix("anyzig.critical: ", format, args);
}

// Writer methods below, internal use only
fn write(
    writer: anytype,
    comptime prefix: []const u8,
    comptime format: []const u8,
    args: anytype,
    comptime stream: []const u8,
) void {
    nosuspend {
        writer.print(prefix ++ format ++ "\n", args) catch |e| {
            std.debug.print("Failed to write {s}: {}\n", .{ stream, e });
            return;
        };
        writer.context.flush() catch |e| {
            std.debug.print("Failed to flush {s} buffer: {}\n", .{ stream, e });
            return;
        };
    }
}

fn logOutWithPrefix(comptime actual_prefix: []const u8, comptime format: []const u8, args: anytype) void {
    const writer = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(writer);
    const buffered_writer = bw.writer();

    write(buffered_writer, actual_prefix, format, args, "stdout");
}

fn logErrWithPrefix(comptime actual_prefix: []const u8, comptime format: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    write(writer, actual_prefix, format, args, "stderr");
}
