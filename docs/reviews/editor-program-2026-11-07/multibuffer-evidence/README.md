# Multibuffer evidence

Zircon's source-backed multibuffer core and Git attachment were checked on macOS/aarch64 with Zig 0.17.1.

- `./tools/zig build test-multibuffer --summary all`: 3/3 steps, 3/3 source identity/excerpt/anchor tests.
The initial package/Git attachment evidence above is superseded by [the inline-editing evidence](../git-inline-editing-evidence/README.md). The source editor now runs directly in current/context diff rows, and commit tabs live in the main tab strip.
