# Darwin child-process isolation

Build macOS binaries with `./tools/zig`. The pinned Zig 0.17.1 Darwin spawn
implementation creates pipes with `pipe()` and then sets close-on-exec with
`fcntl()`. Another thread can spawn a process between those operations.
Without `POSIX_SPAWN_CLOEXEC_DEFAULT`, that child inherits unrelated pipe ends.

A live failure showed the Python language server retaining the grammar worker's
stdin writer. The worker was blocked in Rust's stdin read after the parent had
closed its own writer. It could not observe EOF and eventually timed out.
This was a descriptor inheritance failure, not slow parsing.

`tools/zig_stdlib_overlay.py` copies the pinned standard library into an ignored
project-local cache and adds `.CLOEXEC_DEFAULT = true` to Darwin's existing spawn
flags. Existing file actions explicitly preserve the requested stdin, stdout,
stderr, progress and `inherit_files`/`inherit_dirs` handles. Other handles close
in the child. This also protects Git, agent and language-server children created
through the same standard-library implementation, without serializing their
work or introducing separate spawn APIs into every package.

The compiler installation and original library are unchanged. Preparation uses
an exclusive lock and atomic directory rename. The helper fingerprints all
library files, verifies the complete cached copy before use, and checks the exact
spawn-source anchor before patching. A library update gets a new cache identity;
a changed spawn implementation requires review. A source/patch/library hash
manifest accompanies the private overlay. Conflicting command-line library
overrides are rejected. Compiler version and formatting queries remain direct.

The wrapper applies the overlay to compilation commands on a Darwin host.
Cross-target builds still select the target's ordinary platform implementation.
Linux-hosted cross-compilation to macOS does not apply this host-gated overlay
and is not an accepted macOS distribution route.
Direct `zig build` bypasses this project fix. Both macOS CI jobs use the wrapper.
Remove this workaround only after the replacement compiler passes the same
regression and real service workload.

Run the deterministic regression:

```sh
./tools/zig run tools/verify_spawn_isolation.zig -lc
python3 -B tools/test_zig_stdlib_overlay.py
```

It deliberately opens two unrelated pipe handles without close-on-exec, modeling
the concurrent creation window. A child must not see them. A second child must
still receive an explicitly declared inherited handle. The unmodified compiler
inherited both unrelated handles; the overlay inherits neither and preserves
the declared handle. The script requires macOS and Python 3.

This fix covers `std.process.spawn` and `std.process.run` in compiled binaries.
The terminal's separate raw `fork`/`execve` path needs its own descriptor and
async-signal-safe lifecycle review under EXT-04/DEV-01. Do not infer that a stdlib
fix proves terminal child isolation or complete process cancellation.
