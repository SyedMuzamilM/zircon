# Comparison verification evidence

Captured 2026-11-06 against Zircon `cc199756e303012e4f6dcee0330568fd6d8b2831`. This directory supports the [detailed audit](../../zircon-vs-zed-audit-2026-11-06.md).

- `portable-rerun.txt` records the verbose `check` build and sequential direct `zig test` invocations. All positive suites pass. The final three compiler rejections are intentional negative-contract fixtures; their diagnostics match the build's expected errors.
- `native-first-run.txt` records verbose native build commands and the first direct rerun of the standalone native window tests. One test fails at `TextDispatchFailed`.
- `native-rerun.txt` records the second standalone failure and separate passing framework, application, settings and real clangd tests. These were sequential, rather than simultaneously competing for native focus.
- PNGs are fresh outputs of the native application journeys. They show test fixtures, not the user's project or a complete OS-window screenshot. Traffic lights are not part of the captured framework scene.

The build commands were `./tools/zig build check --verbose` and `./tools/zig build test-editor-native test-settings-native test-language-real --verbose`. Build test runs can be cached. For fresh execution, the audit parsed each printed `info(verbose): .../zig test ... --listen=-` compile command, removed only `--listen=-`, and ran that argument vector sequentially. The direct `zig test` invocation executes the tests, even when compilation is cached. The full native compile commands are retained in `native-first-run.txt`; portable compile commands are retained in `portable-rerun.txt`.

The standalone failure was reproduced twice. The exact assertion is `log.keys != 1 or log.text != 1` at `packages/zircon_ui/src/platform/macos/window_test.zig:68`. No instrumentation was added to distinguish a missing event from duplicate events. The failure is unresolved; the application-level passing input journeys do not explain it.

No comparative performance data was collected. Test counts and timings in logs describe test execution, not editor latency, throughput or a ranking against Zed.
