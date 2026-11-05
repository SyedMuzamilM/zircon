# Implementation status

Audited on 2026-11-05 against the unchanged [supplied specification](specification/framework-api-v0.1.md), current source and executable checks.

Zircon UI now runs a real native macOS application through `App.openWindow` and `App.run`. The native counter uses the same entity, tree, layout, paint, input and animation path exercised by portable tests. The framework is usable for the editor implementation; it is not the full specification or a production equivalent of GPUI yet.

## Coverage by milestone

| Milestone | Implemented behavior | Remaining work |
| --- | --- | --- |
| Entity runtime | Generational typed handles, stable storage, ownership scopes including windows, scoped borrows, deferred destruction, observations, typed owned events, coalesced notifications | Broader adversarial/load validation |
| UI construction | Const views, nested views/watched dependencies, indexed trees, keys, cleanup, three-phase custom elements, committed/staging generations | More stock controls and accessibility metadata |
| Native layout/render | Flex subset/stacks, CoreText shaping and glyph caret geometry, direct Zig AppKit windows, Metal presentation, clipping, rounding, snapshots | Images/SVG/path effects/shadows, wrapping/grid/baseline, device recovery |
| Interactive runtime | Hit testing, capture/target/bubble, focus and pointer capture, Tab/button defaults, typed shortcut maps, safe close prevention, idle scheduling | Modal focus trapping, native menus/dialogs, richer shortcut sequences |
| Editor foundations | Editable single-line control, clipboard/selection, bounded revisioned native text input/composition, scrolling/virtual-row math, owned workers, tween/spring/color/geometry/presence motion | Full grapheme movement, OS IME acceptance journey, full-document input geometry, accessibility, stock virtual-list/menu widgets |
| Optimization/platforms | Resource limits/counters and Linux portable cross-compilation | Application benchmarks, measured comparisons with Zed, scene caching, Windows/Linux native adapters |

The first four milestones have working foundations. Editor capabilities are partial. Milestones differ greatly in size, so a percentage would imply precision the project does not have. Exporting a type or compiling a target is not counted as complete behavior.

## Editor work

The accepted [editor design](design/editor.md) separates document storage/history, workspace persistence, editor commands/canvas and application chrome. Implementation is underway. Native framework tests do not establish a completed editor or Zed feature parity. LSP, Git, terminal emulation, debugging, extensions and collaboration require their own real implementations and tests.

## Verified commands

```sh
./tools/zig build check
./tools/zig build test-native
./tools/zig build build-native
./tools/zig build counter-native
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```

Portable checks cover entity lifetimes, transaction rollback, layout, custom phases, routing, focus, keyed reconciliation, animations, observers/events, clipboard/editable controls, revisioned snapshots and worker cleanup. Native tests use real AppKit events, CoreText and Metal, decode GPU-produced PNG pixels, and verify click/resize/close and native range/composition selectors. The integrated checkpoint passes88 portable test-runner cases,20 native cases and three expected compiler-error contracts. Test-runner totals include import aggregation cases.

Native selector tests are not a complete OS input-method journey. The point query resolves the published caret, not arbitrary document coordinates. Emoji glyph coverage is monochrome. Async GPU failure recovery and whole-process performance have not been established.

The original specification, source research and design candidates remain for future reference. Rejected NanoUI/editor adapters and C/Objective-C bridge files remain removed. Active dependencies do not contain NanoUI or GPUI.
