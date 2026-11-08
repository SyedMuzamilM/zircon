const std = @import("std");
const package = @import("zircon_widgets");
test {
    std.testing.refAllDecls(package);
}
