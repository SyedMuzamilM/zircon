//! User journeys shared by portable and native application test roots.
const agent_tests = @import("agent_tests.zig");
const buffer_controls_tests = @import("buffer_controls_tests.zig");
const diff_layout_tests = @import("diff_layout_tests.zig");
const experience_tests = @import("experience_tests.zig");
const git_controls_tests = @import("git_controls_tests.zig");
const grammar_retry_tests = @import("grammar_retry_tests.zig");
const language_actions_tests = @import("language_actions_tests.zig");
const language_lifecycle_tests = @import("language_lifecycle_tests.zig");
const recovery_tests = @import("recovery_tests.zig");
const settings_tests = @import("settings_tests.zig");
const sidebar_tests = @import("sidebar_tests.zig");
const ui_ownership_tests = @import("ui_ownership_tests.zig");
const workspace_polish_tests = @import("workspace_polish_tests.zig");
test {
    _ = recovery_tests;
    _ = agent_tests;
    _ = workspace_polish_tests;
    _ = ui_ownership_tests;
    _ = experience_tests;
    _ = buffer_controls_tests;
    _ = settings_tests;
    _ = sidebar_tests;
    _ = language_lifecycle_tests;
    _ = language_actions_tests;
    _ = grammar_retry_tests;
    _ = git_controls_tests;
    _ = diff_layout_tests;
}
