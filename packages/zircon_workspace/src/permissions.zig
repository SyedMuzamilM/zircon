//! File permission values with a portable Windows fallback.
const std = @import("std");
const builtin = @import("builtin");
pub fn file(mode: std.posix.mode_t) std.Io.File.Permissions {
    return if (comptime builtin.os.tag == .windows) .default_file else .fromMode(mode);
}
pub fn dir(mode: std.posix.mode_t) std.Io.File.Permissions {
    return if (comptime builtin.os.tag == .windows) .default_dir else .fromMode(mode);
}
