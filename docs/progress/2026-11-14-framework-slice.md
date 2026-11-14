# Framework feature slice: lists, SVG, scene animation, and command sequences

This slice implements the first macOS/headless framework gaps identified in the current GPUI audit. Linux and Windows adapters remain outside the scope.

## Delivered

- `controls.UniformList` paints only visible fixed-height rows plus overscan.
- `controls.VariableList` accepts caller-supplied prefix and inverse-prefix functions so indexed trees can virtualize variable-height rows without scanning a million items.
- `graphics.images.Image.loadSvg` rasterizes SVG bytes through AppKit and publishes the same premultiplied RGBA8 image contract as ImageIO assets.
- `controls.Svg` retains an SVG image and submits a transformed scene instance.
- Metal image instances support scale, translation, rotation, and opacity transforms.
- Scene animation tracks update image transforms during presentation without rebuilding the frame tree, layout, or text shaping.
- `fillLinearGradient` and layered `shadowRect` primitives are available in the painter.
- `SequenceMap(Action)` adds context-aware multi-stroke command resolution while retaining the existing single-chord `Keymap` API.
- `build-bench-list` builds `zircon-ui-list-bench`, a million-item fixed-list CPU benchmark.
- The project sidebar now uses the compositional virtual-list API, preserving its existing row buttons, selection keys, drag handlers, and scroll state while composing only visible rows.
- The image viewer and Markdown image loader accept `.svg` assets through the native SVG decoder.
- Explicit keyed subtrees can opt into persistent scene-range replay. Rect/text/line/gradient ranges are fingerprinted by style, content, hover state, inherited opacity, bounds, and clip; image/custom ranges remain uncached unless they provide a stable fingerprint contract.
- The same keyed leaf contract now feeds an intrinsic layout cache for text and custom leaves. Repeated frames reuse measured leaf sizes when available constraints and fingerprints match; parent arrangement remains fully validated.

## Verification

```text
./tools/zig build check                         PASS
./tools/zig build test                         PASS
./tools/zig build test-native --summary all    37/37 PASS
./tools/zig build build-bench-list -Doptimize=ReleaseFast PASS
./zig-out/bin/zircon-ui-list-bench 1000000 200
```

The list runs painted 9,198 rows over 200 iterations and emitted 8,390 scene items. Local smoke runs measured 0.08–0.27 ms total for the CPU loop. This is a virtualization smoke measurement, not a GPUI comparison: it excludes GPU submission, text shaping, native event delivery, and an equivalent Rust workload.

## Remaining high-value work

The retained scene path now covers compositor-only image transforms and explicit keyed scene-range replay. Layout reuse currently covers keyed leaf intrinsic measurement; full subtree arrangement reuse, accessibility semantics, vector path tessellation, richer text/emoji, native menus/dialogs, and editor-side incremental wrapping/LSP/Git work remain separate slices. The next benchmark work should add an equivalent GPUI Rust driver for the list, then compare both implementations on identical million-row, editor, text, image, and SVG workloads.
