# Zed Vim editing and rendering reference

Inspected 2026-11-06 in the read-only checkout `/tmp/zircon-research/zed`. All upstream citations pin commit [`4a6121bb0f10c6e8037b741b7dc0a4cd639ae289`](https://github.com/zed-industries/zed/tree/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289). Files absent from the sparse working tree were read with `git show HEAD:<path>`.

This document records source observations, proposed Zircon implementation lessons, and acceptance criteria. Zed was not launched, its tests were not run, and no runtime timings, allocation counts, frame rates, or comparative speedups were measured. Test names and upstream comments are evidence of intended behavior, not measured facts. Zircon implementation and profiling belong to the parent task. Only this research document was written.

## Vim state, counts and operators

### Source observations

Zed models `Normal`, `Insert`, `Replace`, `Visual`, `VisualLine`, and `VisualBlock` as distinct `Mode` variants. The same enum also contains Helix modes, which are separate scope. `Vim` holds the mode, previous mode, operator stack, selected register, transaction state and stored visual state. This is an editor add-on, with its own key-context extension. See [mode definitions][modes] and [Vim state/add-on][vim-state].

| Behavior | Source observation |
| --- | --- |
| Normal motions | `motion` consumes the count and forced-motion state, then sends normal-mode commands to `normal_motion`. That function chooses plain cursor movement or the pending operation, including change, delete and yank. [Motion dispatch][motion-dispatch], [normal dispatch][normal-motion]. |
| Character visual mode | Entering a visual mode from a nonvisual mode expands an empty selection right by one character. Visual motion keeps the current and anchor characters included, compensating when direction reverses. The internal selection remains a range with direction; it is not just a painted caret. [Mode transition][switch-mode], [visual movement][visual-motion]. |
| Visual line | Vim settings synchronization sets the editor's `line_mode` only for `VisualLine`. Selection layout expands the source range to line boundaries, and `MotionKind::for_mode` gives this mode linewise semantics. [Editor synchronization][vim-sync], [selection layout][selection-layout], [motion kinds][motion-kinds]. |
| Visual block | `visual_block_motion` preserves a horizontal range in layout coordinates, measures each row, converts its x positions with `closest_index_for_x`, and builds separate selections. It skips rows whose text does not reach the rectangle's left edge. It advances between buffer rows to skip soft-wrap continuation rows. [Block selection][visual-block]. |
| Counts | `push_count_digit` appends to a pre-operator count or post-operator count, using checked digit arithmetic and an `isize::MAX` bound. `take_count` multiplies the two optional counts, each defaulting to one, then consumes them. Its multiplication itself is plain multiplication, so this source does not establish overflow safety for every combined count. [Count accumulation][count-digits], [count consumption][take-count]. |
| `0` | The shared motion context maps `0` to start of line. `VimControl && VimCount` overrides it with the digit action once a count exists. Thus `0` and `10j` can coexist. [Shared bindings][vim-keys], [count bindings][normal-keys]. |
| Repeated operators | Normal `d`, `c`, and `y` push operators. Operator-specific contexts then bind a repeated operator to `CurrentLine`, for example `vim_operator == d` plus `d`. This makes `dd` a linewise operation without inserting either character. [Normal bindings][normal-keys], [operator bindings][operator-keys]. |
| Edit transaction | `delete_motion` expands a motion into selected ranges, copies register contents, deletes in a transaction, and restores a clipped cursor. Linewise deletion handles the final line by consuming the preceding newline if no following newline exists. [Delete implementation][delete-motion]. |
| Cancellation | `clear_operator` consumes counts and forced-motion state, clears the register/operator stack, and synchronizes settings. Blur also clears the operator. Mode transitions clear operator/register state and reconcile selections. [Cancellation][clear-operator], [blur behavior][vim-blur], [transitions][switch-mode]. |

### Implementation lessons for Zircon

Keep command interpretation separate from mutation. A small command state should contain the editing mode, pending operator, pre/post counts, and any pending character argument. A motion should resolve to a destination or typed range, with characterwise inclusive/exclusive or linewise semantics, before delete/change/yank applies it. A block operation needs per-row ranges. These are proposed interfaces, not a claim that Zircon needs Zed's Rust add-on or operator stack.

Use the existing editor transaction, selection and clipboard/register services. Counts should alter the resolved command, rather than dispatching independent edits that create many undo entries. Check both digit accumulation and the final multiplication, cap work at useful document limits, and clear incomplete commands on Escape, blur and editor replacement. Do not copy Zed's plain count multiplication as an overflow policy.

Store visual anchor and active end independently of normalized range order. Reversing direction must keep the anchor character selected. Linewise and blockwise selections require explicit semantics for copying, replacing, deleting and undo, even when their highlight looks similar to an ordinary multiline selection.

## Text input suppression and binding contexts

### Source observations

`editor_input_enabled` returns false in normal and all three visual modes. Insert enables ordinary input unless a waiting operator owns the character. `expects_character_input` is separate, allowing commands such as find/replace to request a character without enabling ordinary insertion. Synchronization also changes cursor shape, line-end clipping, cursor offset inside a selection and line mode. Normal mode clips at line ends; visual modes do not use that same clipping flag. See [input policy][vim-input-policy] and [synchronization][vim-sync].

Suppression exists at the editor's text-input boundary, not only in key bindings. `replay_insert_event` and `replace_text_in_range` emit `InputIgnored` and return when input is disabled. `replace_and_mark_text_in_range` also returns without editing. The UTF-16 selection query returns no selection when disabled unless explicitly asked to ignore the restriction, with an upstream comment connecting this to the alphabetic-key IME menu. The internal `handle_input` routine does not itself check `input_enabled`; callers at the boundary matter. See [ordinary input][editor-input] and [native text/IME handling][ime-input].

Vim subscribes to `InputIgnored` and interprets text for pending character commands. `input_ignored` turns a pending `FindForward` or `FindBackward` into a motion using the received character. Therefore, disabling document insertion must not discard every command argument. [Event routing][input-events], [waiting-character handling][ignored-input].

`extend_key_context` exposes these dispatch properties:

| Context | Meaning in the inspected implementation |
| --- | --- |
| `vim_mode` | `normal`, `insert`, `replace`, or `visual`; all three visual variants share the `visual` binding value. A pending operator can replace this value with `operator`, `waiting`, or `literal`. |
| `vim_operator` | Active operator identity or `none`, allowing operator-specific continuations. |
| `VimControl` | Added for command modes such as normal, visual and operator, excluding insert and ordinary waiting-character states. |
| `VimCount` | Added when the applicable pre/post count exists, enabling the special `0` binding. |

These are derived properties, not independent booleans that callers toggle. [Context construction][vim-context]. The default keymap uses `VimControl && !menu` for shared motions, mode predicates for insertion/visual actions, and additional completion/search/menu predicates where necessary. GPUI's [key dispatch documentation][key-dispatch] explains action bindings attached to element contexts. A `Markdown` context is also installed by the Markdown element, independently of the source editor. [Markdown element][markdown-layout].

### Implementation lessons for Zircon

Make one function derive text-input policy, caret shape, selection policy and key context from command state. Install the new policy in the same update as the mode change. A status label alone cannot prevent native `insertText` or marked-text callbacks from editing the buffer.

Route a key through command dispatch once. Consume handled motions, operator prefixes and completed commands before the ordinary text path. At the text boundary, reject insertion in command modes while still forwarding text to an explicit pending-character consumer. Preserve Insert-mode composition and UTF-16 replacement behavior.

Contexts must follow focus. Search boxes, settings pickers and other editable controls should receive their own typing even while the document is in normal mode. Completion menus need their own arrow/Enter/Escape handling. Derive normal/visual/operator contexts from the active editor, rather than treating Vim as a window-wide interception of every letter.

## macOS deletion shortcuts

### Source observations

The pinned [macOS default keymap][mac-keys] binds the following under `Editor`, with `use_key_equivalents: true`. `alt` is the keymap spelling for Option.

| Shortcut | Editor action |
| --- | --- |
| Cmd+Backspace | `DeleteToBeginningOfLine` |
| Cmd+forward Delete | `DeleteToEndOfLine` |
| Option+Backspace | `DeleteToPreviousWordStart`, `ignore_newlines: false`, `ignore_brackets: false` |
| Option+forward Delete | `DeleteToNextWordEnd`, with the same options |
| Backspace / forward Delete | `Backspace` / `Delete` |

The keymap also defines other actions for the same chords in terminal, project-panel and Git contexts. These are editor bindings, not a license to bind destructive document actions globally. The source normal-mode keymap overrides plain forward Delete with `vim::DeleteRight`. [Normal bindings][normal-keys].

The line-deletion implementations select toward the beginning/end with `stop_at_soft_wraps: false`, then call Backspace/Delete in a transaction. `DeleteToBeginningOfLine.stop_at_indent` defaults to false, so the plain binding targets the logical beginning rather than an indentation stop. Word deletion extends an empty selection with word/newline-aware movement and bracket adjustment, then inserts an empty string; a nonempty selection bypasses that extension. Read-only editors return early. [Line deletion][line-delete], [action defaults][delete-defaults], [word deletion][word-delete].

### Implementation lessons for Zircon

Normalize backward and forward delete as distinct keys before applying modifiers. On a compact Mac keyboard, the key labelled Delete usually produces backward deletion; use a real native-event check for Fn+Delete rather than assuming a keycap name. This is a proposed platform validation, not a result obtained from running Zed.

Implement each chord as an editor action that reuses movement, transaction and selection logic. Use logical line boundaries even when a line wraps visually. Specify the behavior at column zero, line end, blank lines, EOF and a nonempty selection with explicit tests; the shortcut names alone do not define those cases. Command-mode input suppression should not accidentally disable deliberate edit actions, and an action plus its native text callback must not delete twice.

## System font discovery and custom fonts

### Source observations

The Apple text system enumerates Core Text descriptors from `create_for_all_families`, extracts family names, and appends families from its in-memory font source. This code explicitly wraps the descriptor array using Core Foundation's Create ownership rule. `TextSystem::all_font_names` sorts and deduplicates the result. [Apple enumeration][apple-fonts], [text-system API][font-api].

App-provided font bytes go through `add_fonts` into `memory_source`. Family loading tries this memory source first, then `SystemSource`, and applies font features/fallbacks. Thus source supports both platform-discovered families and fonts registered from bytes. It does not by itself establish a user-facing font-file import dialog or live refresh after installing a system font. [Font registration][font-registration], [family resolution][font-resolution].

`FontFamilyCache` retains the discovered family list and provides background prefetch. The picker uses its nonblocking cached-list method, falling back to the current family if the list is unavailable. Search operates over that family list and rows preview their own family. The inspected cache has no public invalidation method; do not infer automatic discovery refresh from text-layout invalidation. [Family cache][font-cache], [font picker][font-picker].

Registering fonts through the GPUI `TextSystem` clears its font-resolution map and increments a font generation. The line-layout cache observes that generation and drops its old layouts. Its keys include text, font size, font runs, wrap width and forced width; current/previous frame maps reuse shaped and wrapped layouts. [Font API][font-api], [layout cache][line-cache], [layout keys/invalidation][line-cache-keys]. This is evidence of an invalidation mechanism, not a measured cache-hit rate or a persistent whole-document layout cache.

### Implementation lessons for Zircon

Populate font choices from platform family enumeration rather than a fixed list of names or guessed filenames. Persist family identity separately from display text and resolved font handles. Preserve the current choice during filtering and handle a missing family through a visible fallback policy.

Cache enumeration outside painting. Keep family-list generation distinct from text-layout generation. If Zircon supports adding font files while running, explicitly refresh the family list and invalidate font resolution, metrics, shaping, line wrapping, selection geometry and Markdown heights. A settings label changing while glyphs still use the previous face is a failed implementation.

Use font runs and actual shaping metrics for fallback text, emoji, CJK and combining characters. Recompute caret width and line geometry when the family, size or fallback set changes. Arbitrary font-file import is additional product scope unless the parent task explicitly requires it; selecting a user-installed system font is a separate capability.

## Editor selection geometry

### Source observations

Zed distinguishes buffer points from display points. `DisplayMap` composes inlays, folds, tabs, soft wraps and inserted blocks, then exposes a display snapshot. [Display map][display-map]. `SelectionLayout::new` maps source selections into that snapshot, uses contiguous display ranges where possible, expands visual-line ranges, and offsets a forward visual caret to remain inside the selected range. It handles a range ending at column zero specially. [Selection layout][selection-layout].

`paint_highlighted_range` intersects the range with visible display rows, excludes the final row when the range ends at column zero, and derives x coordinates from each laid-out line's `x_for_index`. It applies the same content origin and scroll offsets used for text and clips painting to the text hitbox. The final-row edge differs from intermediate line ends. [Highlight geometry][selection-paint]. Cursor layout also uses shaped-line positions; a zero advance falls back to the em advance. [Cursor geometry][cursor-layout].

Visual block uses measured x coordinates and per-row source mapping rather than multiplying a byte column by an assumed character width. Its source explicitly deals with reversed selections, short lines and soft wraps. [Block geometry][visual-block]. These observations do not prove complete bidirectional-text correctness or every Unicode edge case.

### Implementation lessons for Zircon

Use one display snapshot and one set of shaped line positions for text painting, hit testing, caret placement, selection backgrounds and Git projections. Keep UTF-8 byte offsets, UTF-16 native ranges, grapheme boundaries, source rows and display rows distinct. A highlight should not include a new row merely because its exclusive endpoint is that row's column zero.

Clip per visible row after mapping through wraps and inserted/removed display rows. Whole-line selection needs linewise edit semantics as well as a larger rectangle. Rectangular selection should keep a horizontal goal and resolve individual row ranges from layout. If the initial Zircon implementation assumes monospaced cells, state that limit and still handle tabs, wide glyphs and short rows explicitly.

## Markdown parsing, caching and virtualization

### Source observations

| Layer | What the inspected source does |
| --- | --- |
| Parse state | `Markdown` retains source, `ParsedMarkdown`, image state and pending parse state. `parse` starts a background parse; if one is running, it sets `should_reparse`. Completion installs the result and schedules another parse when needed. This is coalescing of full parse jobs, not evidence of incremental Markdown parsing. [State][markdown-state], [parse scheduling][markdown-parse], [completion][markdown-completion]. |
| Deferred startup | `defer_parsing` postpones the initial parse until `ensure_parsed`, which layout calls automatically. The option's comment says later source updates parse eagerly even off-screen after parsing starts. It is not a visibility-driven suspension policy for all subsequent work. [Options][markdown-state], [ensure parsed][markdown-ensure]. |
| Code highlighting | Background parsing computes `code_block_highlights` and retains them in parsed state. Upstream tests named `test_code_block_highlights_cached_at_parse_time` exercise this behavior, but were not run for this research. [Parse/highlight computation][markdown-parse], [upstream test][markdown-highlight-test]. |
| Element/layout work | `MarkdownElement::request_layout` reads the parsed state, constructs a builder, iterates `parsed_markdown.events` and builds a child element for layout. Prepaint and paint reuse that request-layout result within the element lifecycle. This does not establish reuse of the entire built tree across renders. [Markdown layout][markdown-layout]. |
| Text shaping | GPUI's current/previous frame line caches can reuse equal shaped/wrapped text across layout passes. That is independent of rebuilding Markdown element structure. [Line cache][line-cache]. |
| Images and diagrams | The preview owns a `RetainAllImageCache`. Markdown also stores images by source offset and distinguishes Mermaid rendering cache from per-diagram zoom/scroll state. These caches have different keys and lifetimes. [Preview state][preview-state], [Markdown state][markdown-state]. |
| Scrolling and visibility | The preview wraps a `MarkdownElement` in an `overflow_y_scroll` container with a tracked scroll handle. A rendered line records its bounds intersected with the content mask. The inspected `request_layout` still iterates the full event list. This path does not establish block virtualization or layout work proportional only to visible content. [Preview render][preview-render], [line clipping][markdown-line], [layout traversal][markdown-layout]. |
| Separate virtualization facility | GPUI provides a variable-height `List` backed by a `SumTree`, cached item state and a scroll anchor. Its contract requires notifying it through `splice` or `reset` when offscreen heights change. It recommends `UniformList` for equal-height items. This is a reusable design reference, not a claim that the inspected Markdown preview uses it. [List contract/state][virtual-list]. |

### Implementation lessons for Zircon

Separate the caches by what invalidates them:

| Proposed cached artifact | Required invalidation inputs |
| --- | --- |
| Parsed Markdown and source spans | Source revision and parser options. |
| Syntax runs for fenced code | Code content, language/grammar revision and syntax configuration. Retain semantic runs separately from theme colors where possible. |
| Shaped text and wrapped lines | Text/style runs, resolved font generation, font size, wrap width and shaping options. |
| Block heights and cumulative offsets | Parsed block identity, available width, fonts/line height, padding, table layout, image dimensions and other resolved assets. |
| Paint state | Selection, search, hover and theme colors when they do not affect metrics. |

These keys are a proposed Zircon design. They are not a literal inventory of Zed caches.

Cache the parsed representation across cursor, hover, scroll and unrelated workspace redraws. Keep selection/search paint changes from triggering parse or syntax work. Coalesce source updates and tag asynchronous results with document identity and revision so an old task cannot replace a newer document. Zed's inspected completion temporarily installs a finished parse before starting a requested reparse; stricter stale-result rejection would be a deliberate Zircon policy.

If profiling finds full-document layout on scroll, virtualize stable top-level blocks using cached heights and a cumulative-height index. Render the visible block range plus overscan, preserve a source/block scroll anchor, and invalidate affected heights on width/font/image changes. Tables and fenced blocks have variable heights, so an equal-height row list is insufficient. One huge paragraph or fence remains expensive even with block virtualization; include it in profiling and consider sub-block line virtualization if it is the actual limiter.

Keep source-to-render mapping for selection, copy, search, link activation and editor-preview synchronization. Offscreen content must remain searchable and copyable without requiring every visual element to exist. Clipping pixels after full layout and skipping offscreen layout are different mechanisms; measure them separately.

## Reuse Git diff navigation

### Source observations

Normal-mode `] c` and `[ c` bind directly to `editor::GoToHunk` and `editor::GoToPreviousHunk`. They reuse editor actions rather than implementing a second Git traversal inside Vim. [Normal bindings][normal-keys]. The editor's handlers obtain a snapshot and selection head, then call `go_to_hunk_before_or_after_position` with wrapping enabled. That helper selects the destination at column zero, unfolds its range and requests centered autoscroll. [Next handler][next-hunk], [previous handler][previous-hunk], [shared navigation][hunk-navigation].

The next lookup enumerates snapshot hunks whose start is strictly after the current row, with a wrap fallback. Previous lookup delegates to the snapshot's `diff_hunk_before`, with an EOF fallback. These are not necessarily a perfectly symmetric algorithm. [Hunk lookup][hunk-lookup]. The inspected handlers do not consume a Vim count, so these sources do not establish counted `3]c` support.

### Implementation lessons for Zircon

Bind Vim hunk navigation, toolbar buttons and ordinary editor shortcuts to one existing hunk-navigation action. Share the hunk snapshot used by gutter markers and inline expansion; do not rerun Git synchronously on every navigation key. Map its source destination through the display projection before scrolling. Keep diff metadata generation and repository/file identity attached to asynchronous refreshes.

Make wrapping and destination rules explicit. If counts are supported, implement them in the shared navigation action or an explicit adapter, and clear the count afterward. Do not infer counted support merely because the key runs in normal mode. Existing gutter/Git research remains in [the companion note](zed-gutter-git-implementation.md).

## Proposed acceptance criteria

All checks below are unexecuted requirements for the parent implementation. They are not claims about current Zircon behavior or measured Zed results.

1. **Normal mode and insertion.** With Vim enabled, `h/j/k/l`, word motions and an unbound printable character do not insert text. `i`, `a` and Escape change the mode, caret and native input policy together. Insert mode accepts Unicode text and IME composition. A native text callback after a handled command does not duplicate an edit.
2. **Counts and operators.** On fixed fixtures, verify `0`, `10l`, `2w`, `dw`, `d2w`, `2d3w`, `dd`, `2dd`, `cw` and `yy` with explicit expected bytes, caret and register contents. Undo each mutating command once. Escape after `2d`, blur, and switching documents leave no pending count/operator. Huge counts neither overflow nor hang; EOF and a final line without a newline work.
3. **Visual character and line modes.** `v` includes the character under the caret and keeps the anchor selected while reversing motion. `V` selects logical lines across wraps, including blank and final lines. Delete/yank/change act on their represented ranges, and Escape returns to normal with a valid caret. Mode toggles update bindings without requiring a mouse click.
4. **Visual block.** Ctrl+V makes independent row ranges. Verify forward/reverse rectangles, short/empty rows, tabs, non-ASCII text and soft wrapping. Delete/yank/change use those same ranges. If block insert is delivered, verify the intended per-row insertion and undo grouping; do not count a painted rectangle as complete editing support.
5. **Focus and pending arguments.** A find/replace character argument reaches the pending command without inserting text. Settings search, filename input and buffer search remain editable while the document is normal. Completion/menu handling and Escape do not leak characters or leave a stuck operator after focus changes.
6. **Native macOS deletion.** Exercise actual Cmd/Option plus backward and forward delete in Insert mode and with Vim disabled. Verify word punctuation/whitespace, selection, logical wrapped-line boundaries, start/end of document and read-only input. Establish expected boundary/newline behavior in fixtures. Each operation has one intended undo step and exactly one mutation. Confirm compact-keyboard Fn+Delete normalization through native events.
7. **Fonts.** The picker discovers an installed family absent from the bundled list, searches it, previews it and persists selection. Reopen the app and verify the resolved face and metrics. Test a missing family and Unicode fallback. If runtime font registration is in scope, warm caches first, add the font, refresh discovery, and verify text, wraps, caret, selection and preview heights all use the new generation.
8. **Selection geometry.** Compare text edges, caret and selection after horizontal/vertical scroll, resize, font changes and 1x/2x backing scale. Cover UTF-8 multibyte text, combining characters, emoji, CJK, tabs, reversed ranges, column-zero exclusive endpoints, wrapping and inline removed Git rows. Hit testing and painting must resolve the same source position and stay inside the text viewport.
9. **Markdown invalidation.** On an unchanged document, scrolling, caret movement, hover and unrelated redraws do not reparse it or rehighlight every code fence. Source edits do refresh parsing. Width/font/line-height changes invalidate the necessary layout; image dimension changes update heights without jumping to an unrelated block. Selection, copy, links, search and source synchronization remain correct.
10. **Asynchronous ownership.** Rapidly edit Markdown, switch files and close previews while parsing or image work is pending. Results apply only to their owning document/revision, pending work is bounded, and completed background work cannot revive a closed view.
11. **Virtualization, if implemented.** At a fixed viewport, record blocks visited, blocks laid out and shaped text on every scroll frame. Increasing document size should not force every offscreen block through layout. Scroll to the end and back, resize, load images and change fonts while preserving the anchor. Include a single giant block to expose the remaining limit. Offscreen search/copy must still work.
12. **Git navigation.** Mouse and `]c`/`[c` reach the same fresh hunk destinations, including deletion-only hunks and wrapped/expanded display rows. Test first/last wrapping, a single hunk, no hunks, revert/refresh and a repository switch. Navigation does not dirty the buffer or launch a new synchronous Git diff. Test counts only if explicitly implemented.

## Profiling evidence the parent should collect

This research supplies no baseline or speedup. Collect evidence against Zircon's actual release build, fixed fixtures and real interaction paths before making a performance claim.

| Question | Evidence to record |
| --- | --- |
| What happened during a frame? | Separate parse, syntax, block construction, shaping, height calculation, layout, paint submission and presentation. Record counts alongside durations so a skipped operation cannot look like a faster implementation. |
| Which interaction is slow? | Cold preview open, warm scroll, selection drag, typing with preview visible, font/width change and Git-hunk jump. Measure input-to-present separately from CPU frame work. |
| Does work scale with visibility? | Fixed viewport over increasing document sizes with prose, fences, tables and images. Record total/visible blocks, visited events, layout/shaping calls and cache hits/misses. Use a separate giant-paragraph/fence fixture. |
| Are cache results valid? | Warm identical input, then change one invalidation input at a time: bytes, width, family/size, syntax theme, image size or selection. Verify resulting pixels/geometry and expected cache generation as well as time. |
| Is the result repeatable? | Record source/build revision, optimization mode, fixture hash/bytes, hardware, OS, backing scale, viewport, font and repetition count. Report cold/warm results separately, median and tail latency, allocations/retained memory, and any errors. Keep workloads and completed work equal before/after. |

Choose an interaction budget for the target display before evaluating results. Any numerical budget or speedup belongs to the measured parent report. Source caching and visible-row loops alone cannot prove a frame-time guarantee.

[modes]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/state.rs#L45
[vim-state]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L500
[switch-mode]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1211
[motion-kinds]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/motion.rs#L25
[motion-dispatch]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/motion.rs#L720
[normal-motion]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/normal.rs#L395
[visual-motion]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/visual.rs#L213
[visual-block]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/visual.rs#L291
[count-digits]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1760
[take-count]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1372
[delete-motion]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/normal/delete.rs#L17
[clear-operator]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1806
[vim-blur]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1631
[vim-input-policy]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1441
[vim-sync]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L2284
[editor-input]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/input.rs#L27
[ime-input]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/input.rs#L2820
[input-events]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1157
[ignored-input]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L2055
[vim-context]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/vim/src/vim.rs#L1487
[vim-keys]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/assets/keymaps/vim.json#L1
[normal-keys]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/assets/keymaps/vim.json#L230
[operator-keys]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/assets/keymaps/vim.json#L758
[key-dispatch]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui/docs/key_dispatch.md
[mac-keys]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/assets/keymaps/default-macos.json#L57
[line-delete]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/input.rs#L1114
[delete-defaults]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/actions.rs#L52
[word-delete]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/input.rs#L984
[apple-fonts]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui_apple/src/text_system.rs#L108
[font-api]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui/src/text_system.rs#L287
[font-registration]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui_apple/src/text_system.rs#L264
[font-resolution]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui_apple/src/text_system.rs#L284
[font-cache]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/theme/src/font_family_cache.rs#L1
[font-picker]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/settings_ui/src/components/font_picker.rs#L19
[line-cache]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui/src/text_system/line_layout.rs#L478
[line-cache-keys]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui/src/text_system/line_layout.rs#L730
[display-map]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/display_map.rs#L216
[selection-layout]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/element.rs#L267
[selection-paint]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/element.rs#L6590
[cursor-layout]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/element.rs#L1143
[markdown-state]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L494
[markdown-ensure]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L1231
[markdown-parse]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L1246
[markdown-completion]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L1405
[markdown-layout]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L2633
[markdown-highlight-test]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L5754
[markdown-line]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown/src/markdown.rs#L4416
[preview-state]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown_preview/src/markdown_preview_view.rs#L80
[preview-render]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/markdown_preview/src/markdown_preview_view.rs#L1911
[virtual-list]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/gpui/src/elements/list.rs#L1
[next-hunk]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/git.rs#L964
[previous-hunk]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/git.rs#L2045
[hunk-navigation]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/git.rs#L513
[hunk-lookup]: https://github.com/zed-industries/zed/blob/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/editor/src/git.rs#L2372
