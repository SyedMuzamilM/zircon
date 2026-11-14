# Git interaction performance and sticky file headers

The [pinned Zed source audit](../research/zed-git-latency-sticky-headers-2026-11-11.md) separates excerpt expansion, source-buffer lifetime, background text comparison, and viewport headers. This delivery applies those boundaries to Zircon's existing canvas and multibuffer model.

## Changes

Five-line expansion updates the chosen file's projection and retained source excerpts. It does not reopen files, create source tabs, or request Git status. Other files retain their row and wrap geometry. Selection text still rebuilds for the comparison, so this is not a claim of constant-time expansion.

Git buffers now belong to the workspace independently of tabs. Initial comparison installation loads a source through workspace ownership; subsequent installations reuse retained document identities. Clicking and editing Git text does not create source tabs. Open File still explicitly opens a file. Saving includes all retained dirty Git buffers, including a buffer whose final hunk disappears. Hidden dirty buffers participate in recovery, window save prompts, and worktree-operation protection. Restoring a checkpoint retains these buffers without restoring hidden tabs.

Live edits request a background buffer diff over retained immutable HEAD/index text and source snapshots. Bursts coalesce behind the running job. This path launches no Git subprocesses. Source revision validation rejects stale results before publication. Actual repository refresh, staging, saving, history, and branch operations retain their repository worker. Comparison bases follow their working presentation when switching to history and back.

Git source wrapping shapes only displayed excerpts. Incremental newline edits remap those ranges and preserve unaffected wrapped rows. Publishing a Git edit maps the hidden source tab's selection and document state, but prepares its layout only when that pane shows an editor. This removes a second full-source layout pass from every Git keystroke. New diff installations also reuse unrelated files' geometry.

Git and global search share sticky file-header geometry. One floating header occupies the viewport top, then the next file pushes it out. The normal header reserves its space without painting duplicate controls. Split Git uses one header across both sides. Header clicks keep their normal actions and do not focus the text underneath. Git header padding is opaque to prevent text showing through.

## Regression evidence

The two-file save journey first failed with an extra source tab. It now checks one tab throughout editing, saving and returning to the editor, and zero Git subprocesses while editing. It also verifies that hidden primary-editor wrap builds do not increase during Git typing. Other regressions cover retained-buffer recovery and window close protection, excerpt-only wrap work with Unicode/newline edits, unrelated geometry reuse, header pinning/push-off, and header actions in both views.

Native screenshots: `/tmp/zircon-git-sticky.png` and `/tmp/zircon-search-sticky.png`.

## Performance evidence

The native benchmark drives four context expansions and 24 text edits in fresh optimized processes. Its disposable repository has eight files with 4,000 lines each and 312 hunks. Every edit checks exact document bytes and the submitted scene; every process verifies one source tab, correct expansion counts, and unchanged disk contents. It measures dispatch and native frame submission, not physical input or display scanout.

The initial retained-buffer implementation's [five-run record](../benchmarks/git-interactions-2026-11-11/) showed roughly 8 ms of typing dispatch work. Source inspection and wrap-build counters identified unnecessary hidden source-editor preparation within that work. A follow-up compares that implementation with the visibility gate, using the same frozen driver and alternating fresh processes. This comparison isolates the hidden-layout fix; it does not measure the entire change against the original implementation or compare Zircon with Zed.


The paired follow-up measured 13.37 ms to 11.38 ms for typing through native frame submission, as medians of five run medians. Run-median ranges were 13.19–13.45 ms and 11.16–11.59 ms. Final individual edits ranged from 10.55 to 12.54 ms. Expansion dispatch's final run-median range was 0.42–0.46 ms; its slowest individual sample was 1.36 ms. The complete click includes two frames and takes about 16.6 ms. The [benchmark record](../benchmarks/git-interactions-2026-11-11/README.md) contains raw samples, hashes, the isolated comparison chart, limits and reproduction commands. These numbers do not measure the earlier implementation's reported second-long freezes.

## Final verification

- `test-app`, `test-editor`, `test-git_ui`: 225 passed, 5 platform skips in the full debug run.
- Fresh native suite after the visibility fix: 184 passed, no skips.
- Final optimized build/check/install: all 60 steps succeeded; its executed application tests passed 156 with 5 platform skips; package checks were cached from the preceding full release check.
- Import placement, Zig formatting and `git diff --check` passed. The optimized bundle is `zig-out/Zircon.app`.
- No commits were created. Earlier uncommitted changes remain preserved.
