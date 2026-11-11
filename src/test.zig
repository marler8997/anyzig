//! The root of the unit tests.

test {
    _ = @import("hashstore.zig");
    _ = @import("lockfile.zig");
    _ = @import("minisign.zig");
    _ = @import("TmpFile.zig");
}
