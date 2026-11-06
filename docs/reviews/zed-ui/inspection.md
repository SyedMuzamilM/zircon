# Installed-app comparison, 2026-11-06

The installed reference is `/Applications/Zed Preview.app`, version 1.28.0, arm64. The executable SHA-256 is `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637`. The initial REA observation of the user's already-running Zed window is `ev_505e1abc3a37a1fc27cffccdc943a1acbcea48a0a45d69757f07d91619483ee1`. It showed One Light, 16-point source/UI settings and an existing Markdown visual selection. Only that selected window was captured. No personal source or credentials are included in the retained screenshots.

A separate installed Zed instance used `ZED_STATELESS=1` and `/tmp/zircon-ui-review/zeddata-isolated` for its preferences, extension files and database. This was launched through LaunchServices. A disposable EditorReview Git repository supplied identical Zig files and two modifications to both apps. No Zed update, extension download or personal preference change was needed. The locally installed Zig extension was copied into the disposable profile for lexical highlighting; language servers were disabled there.

REA could not reliably identify the separate instance's launch time/accessibility window, reporting `process-identity-unavailable` and then `ambiguous-window`. Captures therefore used macOS `screencapture -l` with the exact fixture window ID. A local Swift helper sent declared CGEvents to that fixture process, used AX only for window resizing/closing and never edited the user's original project. Capture pixels are runtime observations; this is not a decompilation claim. The helper and full transient capture records remain under `/tmp/zircon-ui-review`.

The completed Zed reference screenshots have no trust prompt or installation notification. The source file has lexical colors. Main windows are 1240 × 820 logical pixels, settings windows 1000 × 700, source size 14 and interface size 13, with One Dark/One Light. `sips` converts Zed's backing-scale captures to their logical dimensions. The PNGs include Zed's native traffic lights. Zircon's native frame snapshots exclude those AppKit controls; native tests verify their real objects. Screenshots are preserved separately, not composited to hide differences.

Zed's dark editor capture has the project panel on the left. The Git captures also show its separate right Git dock; Zircon currently switches its left rail to Git. Light editor/command captures retain the Git dock from the workflow. The two implementations do not have equal pane architecture or identical semantic highlighting. The source selections cover different row ranges; compare continuity, color and geometry rather than pixel equality. These are explicit limits on visual parity.

## Changes supported by the comparison

- Distinct blue text selection in dark mode and lavender in light mode. Selected rows remain neutral; extension-supplied selected colors remain authoritative, with hover blended separately.
- Source-length selection bands include newline cells and fill the whole line height. Blank lines remain visible. Selecting text no longer paints to the right window edge.
- Gutter line numbers have stronger contrast. Folder labels are neutral, matching the installed reference's default hierarchy.
- The command/file picker uses a single search header, compact rows, undimmed source, navigation/confirmation hints, a border and a restrained shadow. Search height is fixed so it cannot collapse under the results.
- Thin divider paint retains the existing 5-pixel drag target. Adjacent tabs share one border. The tab-history chevrons remain because the installed Zed reference also has them.
- Stock text fields, settings controls, popup cards and blame use shared corner tokens. Pill-shaped switches keep a radius derived from their different shape.
- Settings receives the resolved parent appearance before its first field render. Previously reading the still-borrowed workspace during initialization aborted field styling, leaving dark search in a light settings window.
- Completion anchors to the committed caret and supports Up/Down selection. Palette clicks outside dismiss without editing the underlying source.
- Opening a nested source expands its ancestors. Git summaries depend on available editor width. Balanced adjacent changed runs get UTF-8-safe intraline highlights in the combined diff.

## Verification scope

Portable and native journeys cover ordinary UTF-8 input, stale native ranges, composition transactions, macOS deletion, continuous selection, Vim modes/operators, split resizing/focus, font discovery/resolution, settings persistence and appearance, palette filtering/activation/dismissal, Git staging/commits/branches/network/stash/hunks/blame, combined navigation, search and Markdown source/layout/image reuse. Native tests drive hidden AppKit windows with window-bound events; they do not establish full foreground input-method or VoiceOver acceptance. Static screenshots establish no frame-rate or latency result.

New regressions assert initial light search paint, exact palette query height, no full-window palette dimming, outside dismissal, automatic ancestor reveal, completion placement and arrow-key handling. Existing selection tests now assert source-length bands and visible newline cells. The native capture runner also refuses an initially dark field in light settings.

At the first UI pass, arbitrary pane trees, a native menu/terminal/debugger, collaboration, full LSP navigation/refactoring, complete Vim, soft wrapping/grapheme motion and asynchronous Markdown were absent. The third candidate adds soft wrapping and language providers as described below. The other gaps remain visible in the feature assessment.

## Reproduce Zircon captures

Use a disposable Git project with `src/main.zig` and `README.md`, then run:

```sh
./tools/zig build capture-ui-review -Dreview-project=/absolute/project -Dreview-output=/tmp/zircon-review
```

The runner owns hidden native editor windows and opens real settings child windows, exports twelve scenarios in each theme, and closes them at teardown. Settings JSON is written only inside the requested output directory. It leaves the project's bytes and repository history unchanged. Images and hashes from this run are under `evidence/`.

## Second candidate, after the Crouton review

The first candidate is archived under `evidence/round-1/`. Reports ending in `-final.md` refer to that historical candidate. The root manifest now records the next candidate, captured with the native runner from `/tmp/zircon-ui-review/iteration-10`. Reference Zed captures are unchanged. Added scenarios show workspace/split menus, searchable font/theme choices, project search and Markdown. `zircon-dark-completion.png` comes from the native installed-server journey, with a disposable UTF-8 fixture and two completion candidates, at 1200 × 760 rather than the comparison fixture dimensions. It is behavioral evidence, not a matched Zed screenshot.

Changes since the 6/10 review:

- Commit is unavailable until staged changes and a nonblank message exist, and remains unavailable during an operation or conflict. The unstaged fixture verifies the disabled state.
- Extension theme selection derives quieter row and hover fills, including in settings.
- File paths are clickable breadcrumb segments. A Line control reveals the cursor. These are not semantic symbol breadcrumbs.
- Indentation guides and visible-line horizontal overflow thumbs are painted in both panes. A primary-pane sizing defect hid its bottom scrollbar; both canvases now stay inside their pane bounds, checked for all four split directions. Horizontal thumbs represent the visible lines, not a document-wide longest-line index.
- Light syntax tokens have stronger contrast.
- Capture settling now observes multiple idle steps so a document-change refresh launched during a frame cannot escape the wait.

Validation on this candidate: `zig build check test-settings-native` passed, including 57 native tests; unchanged portable results were cached. The Linux test cross-build, ReleaseFast build and generated-icon check passed. These are correctness/build results, not latency benchmarks.

The Gemini first-final report describes incremental/streaming Markdown and broad accessibility too strongly. The inspected Zed source establishes background/coalesced parsing and caching, not incremental event layout. Zircon's native tests do not establish full foreground IME or VoiceOver acceptance. Those statements are not adopted as conclusions here.

The capture runner renders the project-search tab before typing into its field and rejects a snapshot unless real search matches exist and no overlay is open. Earlier transient search captures typed against the preceding frame and were discarded.

## Third candidate

Application source candidate: `2faf2bb`. Evidence was captured with this source before the commit; this section and its manifests are committed separately.

The second candidate and its manifest are archived in `evidence/round-2/`; reports named `*-round-2.md` are historical. Current root images come from the native runner's `/tmp/zircon-ui-review/round-3-final` output, plus the native completion and Markdown regressions. The runner now includes real 700 × 650 windows for narrow editor/palette inspection. Reference Zed images remain unchanged.

This candidate adds viewport word wrapping, the official Zed extension catalog and supported package adapters, bundled common-language grammar/LSP providers, actual ZLS/Pyright initialization/completions, and automatic dot completion. See `../../zed-extensions.md` for exact compatibility and performance limits. Additional package/server captures and hashes are in `../extensions/evidence/`.

Markdown fenced code now receives editor theme token colors, preserves indentation and wraps long words instead of clipping. A new regression failed on the old light code color and passes with color, indentation and preview containment assertions. Native PNG evidence includes the long-token/Unicode light case. Known source suffixes and special filenames now map to useful extension searches. Small-window tests assert canvas containment above the status bar.

The palette uses up to 560 pixels, bounded by a 24-pixel window inset, so long command labels fit in the 700-pixel window. In split editors, only the focused canvas paints an active line and bright line number. A native click regression checks that the highlight moves between panes. Inactive text selection retains its separate theme color.

Validation: `./tools/zig build check test-settings-native`, Linux test cross-build, ReleaseFast build, formatting and generated-icon checks passed. The real-package journey passed again in `/tmp/zircon-zed-native-round-3`, including automatic ZLS completion, acceptance/undo, Pyright, theme/icons, wrapping and catalog installation. All current and archived second-candidate manifest hashes were checked. These checks do not measure runtime latency.

This is still not full Zed feature parity. Current syntax providers parse off the UI thread and reject stale spans, but are not incremental Tree-sitter sessions; imported theme styles and API capabilities are partial. Markdown parsing/layout are cached, not incremental background rendering. Reviews must preserve these distinctions.
