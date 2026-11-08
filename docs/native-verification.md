# Fresh native verification

Native checks use real AppKit, CoreText, Metal and owned child processes. Their result depends on the environment, so native test run steps always execute. Compilation remains cached. Portable test results retain their existing cache policy.

From the repository root on macOS:

```sh
./tools/zig build test-native-fresh --summary all
```

This runs the standalone window/input suite, framework/renderer suite, editor application journeys and settings regression in that order. Dependency edges serialize them even when the build compiles artifacts concurrently. Exit status is nonzero on a test failure; the summary lists passed, failed and skipped tests.

For the short input/window check:

```sh
./tools/zig build test-native-window --summary all
```

Run this twice to confirm fresh execution. Both summaries must contain `run test ... pass`, rather than `run test cached`. `compile test ... cached` is expected and does not skip execution.

The existing `test-native`, `test-editor-native`, `test-settings-native` and `test-language-real` run steps also always execute. The optional real-server command includes the same preceding native suites, then checks installed Apple clangd:

```sh
./tools/zig build test-language-real --summary all
```

The `native-test-filter` build option filters only the native application suite. Do not use it when claiming full application coverage. Avoid running separate native builds simultaneously; dependency serialization applies inside a build invocation, not across different shell processes or threads.

## Input routes and evidence

Surface checks and application journeys send synthetic keys with `NSWindow.sendEvent` through the chosen window's real first responder. This tests native key interpretation and text callbacks without relying on the user's active application staying unchanged.

A separate foreground check posts a key through `NSApplication`, changes the key window, then verifies delivery to the new key window. The event's original `windowNumber` does not bind queued key delivery to that window. A second check verifies that window-bound delivery continues to reach the original target after a focus change.

The foreground check reports `SkipZigTest` when macOS does not grant app activation. This is distinct from passing window-bound routing. Exact key and committed-text counts remain assertions. Failures report counts, application activation, key-window state and first-responder identity.

Two route records are written by the standalone suite:

- `/tmp/zircon-native-input-mode.txt` identifies window-bound delivery.
- `/tmp/zircon-native-queued-input-mode.txt` records `PASSED` foreground queue coverage or `SKIPPED` activation unavailability.

The native menu journeys use the same distinction. One sends an actual menu action to the window's responder and always asserts document creation. The foreground journey waits for app activation and the expected key window before exercising AppKit's responder-chain routing. If activation is denied and no key window exists, it reports `SkipZigTest`. An active app with the wrong key window still fails. `/tmp/zircon-native-menu-input-mode.txt` records `PASSED` or the activation-related `SKIPPED` reason.

Read these with the current invocation's exit status and summary. They are fixed temporary paths and can be overwritten by a later run; a mode file by itself is not a test result. Full foreground IME acceptance, dead-key layouts and accessibility remain separate checklist tasks.

The macOS native CI job runs `test-native-fresh` and uploads the build log plus both route records even on failure. A foreground skip must remain visible in the summary/artifact; do not relabel it as full OS-input acceptance.

## Settings regression

The settings journey retains the synchronous AppKit blur/borrow regression, child visibility/centering, reopen, hover and Cmd+, checks. Mouse opening follows the current UI path through Workspace menu, then Settings. It does not assume the removed status-bar gear exists.

The [November 7 progress record](progress/2026-11-07-baseline.md) explains the original failures and the validation for this change.
