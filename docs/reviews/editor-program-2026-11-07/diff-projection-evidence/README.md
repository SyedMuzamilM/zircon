# Diff projection and toolbar slice

This slice adds a worker-built Git diff projection. It groups hunks by file, counts additions/deletions, prepares unified and split row maps, tracks collapsed file paths, computes file/hunk offsets and exposes stable command handlers. The diff worker transfers the projection with the patch result. The view adds collapse-all, unified/split, previous/next hunk controls and file headers with stage and Open File actions. Existing patch rows remain the renderer for now, so source-backed typing is not yet implemented.

OpenCode's three findings were fixed before this slice was recorded. Transport-level grammar errors clear pending jobs and schedule a bounded retry. Syntax failures do not overwrite a newer general status error. Net-zero Git files omit misleading `+0` badges. The portable suite passes77 tests with four explicit skips. The repeated native chain passes105 tests with one expected foreground-activation skip on the successful rerun. The first native run had one timing timeout in the persistent-failure fixture; the targeted test passed36/36 and the clean rerun passed. This is a scheduling-sensitive test observation, not a performance claim.

The new projection model test uses a real temporary Git repository and verifies two file groups, counts, split/unified rows, collapse height and offsets. No editable excerpt mapping, hunk staging, commit toolbar action, or persistent parser worker is claimed yet.

OpenCode follow-up status ownership fix is source-backed; the retained tests cover stale and recovery error ownership, while a dedicated current-revision time-ordering fixture remains open.
