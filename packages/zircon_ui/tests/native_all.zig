const native_icon_tests = @import("native_icon_tests.zig");
const native_image_tests = @import("native_image_tests.zig");
const native_renderer_tests = @import("native_renderer_tests.zig");
const native_runtime_tests = @import("native_runtime_tests.zig");
const native_text_tests = @import("native_text_tests.zig");
test {
    _ = native_image_tests;
    _ = native_icon_tests;
    _ = native_runtime_tests;
    _ = native_text_tests;
    _ = native_renderer_tests;
}
