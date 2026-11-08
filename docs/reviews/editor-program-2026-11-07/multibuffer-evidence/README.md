# Multibuffer evidence

Zircon's source-backed multibuffer core and Git attachment were checked on macOS/aarch64 with Zig 0.17.1.

- `./tools/zig build test-multibuffer --summary all`: 3/3 steps, 3/3 source identity/excerpt/anchor tests.
- `./tools/zig build test-app --summary all`: 5/5 steps, 94 application checks passed and four existing skips. The Git experience opens two changed files, asserts that the combined projection retains both source documents, and keeps patch rows display-only until the editor view is wired.
- `./tools/zig build check --summary all`: 45/45 steps succeeded.
- `./tools/zig build test-build -Dtarget=x86_64-linux-gnu --summary all`: 15/15 portable compilation steps.
- `./tools/zig build test-build -Dtarget=x86_64-windows-gnu --summary all`: 15/15 portable compilation steps.

The package proves source identity, excerpt projection, atomic multi-source replacement, source revision metadata, cross-excerpt edit rejection, stale revision rejection, anchor remapping and source snapshot replacement. It does not claim a complete editable Git editor yet. UTF-16 display points, grouped multi-document undo, diff transforms, context expansion, search/diagnostics migration and the view editor remain open WORK-02 slices.
