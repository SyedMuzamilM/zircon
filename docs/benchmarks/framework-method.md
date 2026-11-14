# Zircon/GPUI framework benchmark method

This is the comparison protocol for the macOS-only framework pass. The GPUI side must use the pinned Zed commit from the [current audit](../research/zed-gpui-gap-audit-2026-11-14.md). Linux and Windows are excluded.

## Scenarios

1. **Uniform million-row list**: one million rows, 20 px height, 1,200 × 820 viewport, alternating row colors, 200 scroll positions. Render only visible rows and overscan.
2. **Variable-height million-row list**: one million rows with deterministic heights from 16–48 px, indexed prefix sums, 200 scroll positions.
3. **Editor**: 32 KiB and 1 MiB UTF-8 buffers, wrapped/unwrapped, middle insert/delete/undo, 20 inputs, warm and cold shaping caches.
4. **Text**: 5,000 labels with fallback fonts, warm/cold font and shaped-line caches.
5. **SVG/image**: 1,000 SVG images, cache warm/cold decode, 60 FPS transform animation, and a multi-frame image playback case where supported.
6. **Idle/compositor path**: cursor blink, hover change, scroll-only update, and scene-only SVG transform. Verify whether layout/paint work runs again.

## Measurements

Record p50/p95/p99 CPU frame time, input-to-submit time, GPU submission time, allocations/count and bytes, scene item count, nodes visited, rows painted, text bytes shaped, cache hit/miss counts, and process RSS. Use ReleaseFast/optimized builds, the same machine, the same display scale, and identical timing boundaries. Report 60 Hz and 120 Hz budgets separately.

Zircon list smoke driver:

```sh
./tools/zig build build-bench-list -Doptimize=ReleaseFast
./zig-out/bin/zircon-ui-list-bench 1000000 200
```

Existing Zircon editor drivers:

```sh
./tools/zig build build-bench-editor build-bench-scroll -Doptimize=ReleaseFast
```

The first million-row result is a CPU virtualization smoke measurement. It does not compare against GPUI or include GPU submission. The comparison begins only after an equivalent Rust driver exists with the same rows, viewport, item content, iterations, and timing interval.
