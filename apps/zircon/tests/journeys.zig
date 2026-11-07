//! User journeys shared by portable and native application test roots.
test {
    _ = @import("agent_tests.zig");
    _ = @import("workspace_polish_tests.zig");
    _ = @import("experience_tests.zig");
    _ = @import("buffer_controls_tests.zig");
    _ = @import("settings_tests.zig");
    _ = @import("language_lifecycle_tests.zig");
    _ = @import("grammar_retry_tests.zig");
    _ = @import("git_controls_tests.zig");
}
