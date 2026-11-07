//! File permission values with a portable Windows fallback.
const builtin = @import("builtin");
const std = @import("std");
pub fn file(mode: std.posix.mode_t) std.Io.File.Permissions {
    return if (comptime builtin.os.tag == .windows) .default_file else .fromMode(mode);
}
pub fn dir(mode: std.posix.mode_t) std.Io.File.Permissions {
    return if (comptime builtin.os.tag == .windows) .default_dir else .fromMode(mode);
}
