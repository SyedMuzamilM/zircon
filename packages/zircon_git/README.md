# Zircon Git

A UI-independent package for real Git repositories. It uses the system `git` executable through argument arrays, never a shell. The application runs these blocking operations in worker jobs and serializes repository mutations.

```zig
var repository = (try git.Repository.discover(allocator, io, project_path)) orelse
    return error.NotARepository;
defer repository.deinit();
var status = try repository.status(allocator);
defer status.deinit();
var patch = try repository.diff(allocator, "src/main.zig", false);
defer patch.deinit();
```

`Repository` owns its canonical worktree root and most recent command-error text. Move it rather than copying it. Query methods update `last_error` on command failure, so a repository value must not be used concurrently without caller synchronization. Independent jobs can discover their own repository values. `lastError()` borrows the retained stderr until another failure or deinitialization.

## Queries and ownership

- `status(a)!Status` parses porcelain v1 with NUL-delimited paths. Status owns an arena, branch, entries, `unborn` and `detached`. Each entry includes its exact path, optional rename source, index/worktree change classifications, and staged/unstaged flags. Spaces, Unicode and newlines in paths are preserved.
- `diff(a, ?relative_path, staged)!Diff` returns unified patch text and parsed hunks/lines. Hunk and line numbers follow Git's one-based patch convention; omitted line numbers are null. Binary patches retain their descriptive text without invented text hunks. `Diff.deinit()` releases the result.
- `commitDiff(a, full_oid, ?relative_path)!Diff` and `fileAt(a, full_oid, relative_path)![]u8` load the selected historical patch/content. They require full hexadecimal object IDs.
- `history(a, limit)![]Commit` returns full object IDs, author/email, timestamp and subject. Use `deinitHistory(a, commits)`. An unborn repository returns an empty list.
- `baseline(a, relative_path, .head/.index)![]u8` returns owned bytes. A path absent from the requested baseline returns empty bytes. Other command failures remain errors.
- `blame(a, relative_path, one_based_line, ?unsaved_contents)!Blame` returns the real line-porcelain author, commit, timestamp, summary, content and uncommitted identity. Unsaved content is written into an exclusive private temporary file under the Git metadata directory and removed on all exits. `Blame.deinit()` releases the result.
- `relativePath(a, absolute_or_relative)![]u8` converts workspace-canonical paths and refuses paths outside the worktree. Callers should canonicalize symlinks through their workspace model first.

All result storage remains valid independently of later repository operations. No result borrows a subprocess output buffer owned by another value.

## Mutations

`stage(paths)` stages exactly the named on-disk paths. `unstage(paths)` restores requested index entries from HEAD, with a safe cached-removal fallback for an unborn repository. Both preserve working file bytes. `commit(message)` commits only the current index, using the exact message and the repository's hooks/signing configuration. It does not stage other changes or bypass failed hooks.

Paths are relative and may not contain NUL, `..` components or `.git` components. Global literal-pathspec mode prevents a filename resembling `:(glob)*` from staging unrelated paths. Error results retain the command's stderr for a useful UI message. These operations change the repository only when the application explicitly invokes them; tests mutate temporary repositories only.

## Unsaved line gutters

`diffLines(a, base, current)![]LineChange` returns an owned array of added, modified or deleted zero-based half-open line ranges. Each record carries `start/end` in current content and `old_start/old_end` in the baseline. Deletions have `start == end`; attach the marker to the following surviving row or EOF. Final-newline-only changes are preserved.

Equal prefixes/suffixes are trimmed before LCS matching. The remaining table is capped at two million cells. Larger ambiguous blocks become one conservative changed range instead of allocating unbounded quadratic memory. This is an explicit accuracy/work tradeoff for very large unrelated regions, not an optimal-diff guarantee. Input bytes are not copied into the result. The application associates results with its captured document revision and discards stale results.

## Process limits and verification

Finite commands have a 30-second read timeout, a 64 MiB stdout limit and a 1 MiB stderr limit. Timeout or output-limit errors stop the owned child. This package does not provide mid-command cooperative cancellation; the application can supersede a result and must check its generation before displaying it. Repository configuration, Git hooks, signing agents and filesystem races can still cause command failures, which are reported without pretending the operation succeeded. A timeout or output-limit failure can happen after a mutation was published. Refresh repository state before deciding whether to retry; this package cannot roll back a completed Git operation.

With Zig0.17.1:

```sh
./tools/zig build --build-file packages/zircon_git/build.zig check
./tools/zig build --build-file packages/zircon_git/build.zig test-build -Dtarget=aarch64-linux-gnu
```

The suite exercises real temporary repositories with unborn/detached HEADs, staged/unstaged/untracked and renamed files, Unicode/newline paths, history, saved/unsaved blame, hook rejection, exact pathspecs and error retention. Separate parser/gutter tests cover allocation failures, invalid records, final newlines and the bounded-work fallback. Git must be installed for runtime tests. Cross-compilation does not run Git on the target system.
