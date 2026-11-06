# Zircon native editor UI review — Gemini round 2

Reviewer: Gemini (independent review sub-agent).
Target candidate: Zircon commit `335a022` at `/Users/syedmuzamilm/work/expirements/zigpui`.
Installed reference: `/Applications/Zed Preview.app` version 1.28.0 (arm64, SHA-256 `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637`).
Evaluation rubrics: [rubric.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/rubric.md) and [inspection.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/inspection.md).
Evidence set: 35 PNG screenshots documented in [evidence/manifest.json](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/manifest.json) (10 Zed reference captures, 24 deterministic review captures across One Dark and One Light, and 1 native completion capture from the installed-server journey).

---

## Evidence method and inspection limits

- **Inspection tooling**: I inspected the codebase, test suites, build definitions, and evidence files. For image inspection, I wrote standard-library Python decoders to unfilter and sample raw RGBA pixel arrays and used local Tesseract OCR to read text and layout elements.
- **Dimensionality**: Both Zed reference captures and Zircon main editor captures measure 1240 × 820 logical pixels (settings windows at 1000 × 700; `zircon-dark-completion.png` at 1200 × 760 from the native server test).
- **Chrome convention**: Per [rubric.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/rubric.md), Zircon's exported frames omit macOS AppKit traffic lights, which are verified independently in native tests ([native_journey.zig](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/native_journey.zig)); Zed captures include native chrome. This is not treated as a defect.
- **Evaluation limits**: Static screenshots and test results do not establish runtime frame rate, input latency, full foreground IME composition transactions, or VoiceOver screen-reader accessibility.
- **Markdown architecture correction**: Prior claims from the historical Gemini report regarding "incremental streaming Markdown layout" are corrected. Source analysis confirms Zircon implements coalesced background snapshot parsing, generation-based layout caching, and asset caching, not incremental event layout.
- **Parity vs Workflow quality**: This review assesses the UI quality of existing workflows. Full Zed parity (terminal dock, interactive debugger, collaboration/CRDT channels, arbitrary N-pane trees, LSP code actions/refactoring, soft line wrapping) is an out-of-scope inventory. Missing or broken behavior within the rubric scope reduces scores.

---

## Summary scores

| Category | Score | Summary rationale |
| :--- | :---: | :--- |
| **1. Visual hierarchy and geometry** | **1 / 2** | Clickable path/line breadcrumbs, 1px thin dividers with 5px hit targets, visible indent guides, and pane containment with horizontal overflow scroll thumbs are verified. Score remains 1/2 due to lack of AST/symbol breadcrumbs, absence of gutter folding chevrons, and unhandled horizontal overflow in Markdown preview code blocks. |
| **2. Color and typography** | **2 / 2** | Text selection is distinctly separated from row focus (blue in dark mode, lavender in light mode); inactive selection is muted; multiline bands terminate at line length + newline cell; extension selection derives quieter row/hover fills; One Light syntax tokens have strong contrast (>3:1); settings window inputs initialize with light appearance. |
| **3. Menus and controls** | **2 / 2** | Command palette uses a fixed 38px search header, 30px compact rows, undimmed editor background, footer keyboard hints, and outside-click dismissal. Split and workspace menus anchor and clamp to viewport. Searchable font and theme pickers and caret-anchored completion with Up/Down keyboard navigation are evidenced. Shared corner radii (4px/6px/8px) and pill switches are verified. |
| **4. Editor interactions** | **2 / 2** | Native UTF-8 input, composition transactions, macOS line deletion merging multicursors, continuous multiline selection with visible newline cells, Vim modal workflows with `/` find integration, and split focus/resizing are implemented and test-verified. |
| **5. Existing project workflows** | **2 / 2** | Git commit button prerequisites (disabled when unstaged/conflicted/busy/empty) are implemented and verified in pixels/tests. Intraline diff highlights balanced runs. Project search captures show indexed matches across files/buffers. Markdown preview renders cached layouts and assets. Settings window supports searchable pickers and persistence. |
| **Total** | **9 / 10** | **Quality of implemented workflows and visual geometry against the rubric.** |

---

## 1. Visual hierarchy and geometry — 1 / 2

### Verified implementations
- **Clickable path and Line breadcrumbs**: Implemented in [chrome.zig:83-107](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L83-L107) and [shell.zig:308-333](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig#L308-L333). Path segments are split by `/` with chevron icons (`v.icon(b, .chevron_right, c.muted, 10)`). Clicking a directory segment reveals and scrolls to that directory in the project tree; clicking `Line {d}` focuses the pane and reveals the cursor via `editor.reveal(snapshot)`. Verified in `zircon-dark-editor.png` and `zircon-light-editor.png`. Tested in [workspace_polish_tests.zig:200-217](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L200-L217).
- **Divider geometry**: [view.zig:135-137](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L135-L137) renders a 5px drag target containing a 1px visible line (`colors.line`), with hover feedback (`colors.hover`). Pixel inspection confirms a clean 1px divider column between panes and sidebars.
- **Tab styling and adjacent borders**: [chrome.zig:34-40](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L34-L40) eliminates doubled borders between adjacent tabs; active tab background blends seamlessly with document background; tab chevrons match installed Zed Preview 1.28.0 chrome.
- **Indent guides**: Implemented in [canvas.zig:126-138](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L126-L138). Draws vertical 1px lines at tab-width intervals with `line_number` color at alpha 0.2. In `zircon-dark-editor.png`, pixel inspection at line 10 detects guide lines at x=307 and x=341 (exactly 34px / 4-space mono interval) with blended color `(57, 62, 71)`.
- **Pane containment and horizontal overflow indicators**:
  - In [view.zig:90](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L90), `primary` editor is constrained with `min_height = .{ .px = 0 }`, fixing the prior primary-pane sizing defect that allowed canvases to expand beyond pane bounds. Verified across all four split directions in [workspace_polish_tests.zig:36-58](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L36-L58).
  - Horizontal overflow thumb: [canvas.zig:206-212](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L206-L212) paints a 4px high scrollbar thumb at `bounds.y + bounds.height - 7` whenever content overflows the visible pane. Pixel inspection on `zircon-dark-split.png` reveals 2,722 scrollbar pixels at y=789–792 across both split panes.
- **Sidebar collapse**: Tested in [workspace_polish_tests.zig:60-72](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L60-L72), allowing sidebar resizing down to 120px while preserving independent Git panel widths.

### Concrete defects and within-rubric gaps
1. **Lack of AST/Symbol breadcrumbs**: `fileHeader` displays directory path segments and line numbers (`src/main.zig › Line 5`), whereas installed Zed displays structural AST symbols ([zed-dark-editor.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zed-dark-editor.png) shows `src/main.zig › pub Session struct`).
2. **Missing gutter folding chevrons**: Zed displays disclosure fold chevrons (`v` / `>`) in the gutter adjacent to collapsible blocks (e.g. lines 4, 15, 24 in `zed-dark-editor.png`). Zircon's gutter displays only line numbers and git change bars.
3. **Markdown code block overflow clipping**: In [views/markdown.zig:237-268](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/markdown.zig#L237-L268), code blocks render with `wrap: false` and lack horizontal scrollbar thumbs or overflow affordances. In [zircon-dark-markdown.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-markdown.png), line 10 (`const message = "Readable controls, predictable...`) hard-clips at the right container edge.
4. **Horizontal thumb scope limitation**: The editor canvas horizontal thumb calculates length based on visible lines rather than a document-wide longest-line index ([inspection.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/inspection.md)).

---

## 2. Color and typography — 2 / 2

### Verified implementations
- **Selection vs Row focus distinction**:
  - Dark mode: Text selection is blue (`0x3d5275` / rgb `61, 82, 117`), row focus is neutral dark gray (`0x3b414d` / rgb `59, 65, 77`), active line background is `#2f343e` ([theme.zig:11-13](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/theme.zig#L11-L13)).
  - Light mode: Text selection is lavender (`0xc6d2f5` / rgb `198, 210, 245`), row focus is neutral light gray (`0xe2e5ed` / rgb `226, 229, 237`), active line is `#eef1f5`.
  - Inactive selection: Distinctly muted (`0x33425a` dark, `#e0e5f1` light).
  - Pixel inspection of [zircon-dark-selection.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-selection.png) samples `(61, 82, 117)` for selection over `(40, 44, 51)` background; [zircon-light-selection.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-selection.png) samples `(198, 210, 245)` over `(250, 250, 250)`.
- **Selection geometry**: [canvas.zig:145](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L145) calculates selection width as `line.display.caret(end) + font_size * 0.6` when spanning lines. Pixel inspection across rows y=165–343 confirms the selection band ends at x=524–550 and does not spill to the 1240px window edge. Blank lines display a visible newline cell.
- **Extension theme selection handling**: [theme.zig:25-30](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/theme.zig#L25-L30) provides `applySelection()`:
  ```zig
  self.selection = value;
  self.selected = .{ .r = self.sidebar.r * 0.4 + value.r * 0.6, ... };
  self.hover = .{ .r = self.sidebar.r * 0.7 + value.r * 0.3, ... };
  ```
  This derives quieter row and hover fills so extension themes no longer collapse text selection into row focus.
- **Stronger One Light syntax tokens**: In [theme.zig:18](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/theme.zig#L18), light syntax colors were upgraded to high-contrast tones (`#383a42`, `#8a2f94`, `#3c7e35`, `#9c4e00`, `#68717c`, `#5b6370`, `#16647b`). Gutter line numbers and text tokens are asserted to satisfy WCAG contrast (ratio ≥ 3:1) in [all.zig:679-686](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/tests/all.zig#L679-L686).
- **Settings window initial styling**: [settings/view.zig:56-65](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/view.zig#L56-L65) propagates `initial_colors` and `initial_follows_system` during `openChildWindow`. `capture_ui_review.zig:119` asserts `background.r >= 0.8` for light settings. Pixel sampling confirms light search fields `(250, 250, 250)` on first render.

---

## 3. Menus and controls — 2 / 2

### Verified implementations
- **Command palette header and geometry**:
  - Single search header with search icon, fixed 38px query height, and 14px font size ([actions.zig:175-181](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig#L175-L181)).
  - Compact 30px row height ([view.zig:252](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L252)).
  - Footer keyboard hints: "↑ ↓ to navigate", "↵ Confirm", "esc Close" ([view.zig:194](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L194)).
  - Undimmed source: Backdrop scrim alpha is `0` for pickers ([view.zig:226](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L226)); underlying code remains clearly legible in `zircon-dark-commands.png` and `zircon-light-commands.png`.
  - Outside click dismissal: [shell.zig:334-342](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig#L334-L342) dismisses overlay on background click without editing underlying source. Tested in [workspace_polish_tests.zig:160-176](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L160-L176).
- **Searchable font and theme pickers**:
  - Implemented in [settings/view.zig:490-504](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/view.zig#L490-L504) via `floatingPanel`, `choice_query` input, and filtered choice rows.
  - Evidenced in [zircon-dark-font-picker.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-font-picker.png), [zircon-light-font-picker.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-font-picker.png), [zircon-dark-theme-picker.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-theme-picker.png), and [zircon-light-theme-picker.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-theme-picker.png).
  - OCR reads active selection checks (`v One Dark`) and live search inputs ("Search choices...").
- **Anchored popover menus**:
  - Workspace menu ([chrome.zig:138-149](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L138-L149)) and Split menu ([chrome.zig:151-162](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L151-L162)) anchor to button bounds and clamp within viewport bounds. Evidenced in `zircon-dark-workspace-menu.png`, `zircon-light-workspace-menu.png`, `zircon-dark-split-menu.png`, and `zircon-light-split-menu.png`.
- **Completion placement and keyboard control**:
  - In [view.zig:43-51](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L43-L51), completion anchors directly to the text input's committed caret (`input.caret`).
  - [actions.zig:709-715](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig#L709-L715) handles Up/Down arrow key cycling, Enter acceptance, and Escape dismissal.
  - Tested in [experience_tests.zig:316-324](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L316-L324). Evidenced in [zircon-dark-completion.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-completion.png), where pixel sampling verifies the popup anchored at caret coordinates (x=250–450, y=70–150).
- **Shared radii**: Defined in [components.zig:8-10](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/components.zig#L8-L10): `control_radius = 4`, `popover_radius = 6`, `card_radius = 8`. Toggle switches dynamically use `bounds.height / 2` ([settings/view.zig:517](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/view.zig#L517)).

---

## 4. Editor interactions — 2 / 2

### Verified implementations
- **Native text input and transactions**: Core text transactions, surrounding text reporting, selection tracking, and marked text composition are handled via `setTextInput` in [canvas.zig:94-102](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L94-L102). Tested with synthetic events on hidden AppKit windows in [native_journey.zig:18-28](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/native_journey.zig#L18-L28).
- **macOS line deletion**: Deleting backwards by word (`Opt+Delete`) and line (`Cmd+Delete`) handles CRLF line endings at buffer boundaries and correctly merges multicursor ranges. Asserted in [all.zig:674](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/tests/all.zig#L674).
- **Continuous multiline selection**: Verified in [all.zig:530-535](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/tests/all.zig#L530-L535). Line bands fill exact line heights without vertical gaps (`bands[0].y + bands[0].height == bands[1].y`), with empty lines displaying visible newline indicators (`bands[1].width > 0 and bands[1].width < 20`).
- **Vim modal subset**: Normal, Insert, Visual, and VisualLine modes supported with modal operator handling (`dw`, `cw`, `dd`, `yy`, `p`, `u`). Normal mode suppresses native input insertions. Slash search (`/`) activates the focused find field, and Enter returns cleanly to Normal mode ([workspace_polish_tests.zig:132-152](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L132-L152)).
- **Split navigation and focus**: Directional splitting (left, right, up, down) and pane divider dragging tested in [workspace_polish_tests.zig:36-58](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L36-L58). Breadcrumbs return focus to the pane owning the document ([workspace_polish_tests.zig:200-217](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L200-L217)).

### Verified boundaries & capability limits
- Native AppKit tests drive window-bound synthetic events on hidden windows; they do not establish foreground IME multi-stage composition or VoiceOver accessibility compliance.
- Vim implementation covers a targeted editing subset; arbitrary Ex commands, recorded macros, and complex text objects (e.g. `ci"`, `da(`, `gq`) are absent.

---

## 5. Existing project workflows — 2 / 2

### Verified implementations
- **Git workflow and disabled Commit prerequisites**:
  - Implemented in [git_sidebar.zig:53-65](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/git_sidebar.zig#L53-L65):
    ```zig
    const commit_ready = staged and !conflicted and !self.git.busy and std.mem.trim(u8, message_text, " \t\r\n").len > 0;
    var commit_style = v.buttonStyle(c, commit_ready);
    if (!commit_ready) commit_style.background = c.hover;
    ```
  - When prerequisites are unmet (unstaged files, merge conflict, busy operation, or empty commit message), `on_click` is `null`, button background is `c.hover`, and label is `c.muted`.
  - Tested in [experience_tests.zig:399-403](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L399-L403).
  - Pixel inspection of [zircon-dark-git.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-git.png) confirms the commit button area uses hover background `(54, 60, 70)` and muted text, with zero primary blue pixels `(77, 120, 163)`.
- **Intraline Git diff highlighting**:
  - In [git_diff.zig:134-167](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/git_diff.zig#L134-L167), `pairedLine` pairs adjacent balanced deletion/addition runs up to 256 lines. `changedColumns` computes exact UTF-8 character differences and paints a darker intraline highlight (`strong.a = 0.3`).
  - Tested in [experience_tests.zig:405-408](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L405-L408).
  - Evidenced in [zircon-dark-git.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-git.png) and `zircon-light-git.png` across modified revision numbers and hex constants.
- **Project search workflow**:
  - Search captures [zircon-dark-search.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-search.png) and `zircon-light-search.png` show the Project Search panel with 8 matches across `README.md` and `src/main.zig`, file headers, match counters, and source excerpts.
  - [capture_ui_review.zig:114](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/capture_ui_review.zig#L114) asserts search results settle before capturing (`if (!try app.read(owner, Ops.searchReady, .{})) return error.ReviewSearchNotReady`).
- **Markdown preview workflow**:
  - Evidenced in [zircon-dark-markdown.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-markdown.png) and `zircon-light-markdown.png`. Side-by-side split displays formatted headings, lists, inline code, and syntax-highlighted Zig code blocks.
  - Clicking links or headings navigates to the source document offset via `source_offset` tracking ([markdown.zig:90-104](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/markdown.zig#L90-L104)).
  - Asset caching reuses decoded images across generations when inode/mtime/size match ([markdown.zig:160-174](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/markdown.zig#L160-L174)).
  - Markdown architecture is coalesced generation parsing, not incremental streaming event layout.
- **Settings workflow**:
  - Evidenced in [zircon-dark-settings.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-settings.png) and `zircon-light-settings.png`. Settings categories (General, Appearance, Editor, Version Control), toggle switches, and font/theme pickers persist cleanly to `settings.json`.

---

## Verification checklist of candidate changes

| Candidate change | Status | Source & Evidence verification |
| :--- | :---: | :--- |
| **Disabled Commit prerequisites** | **Verified** | [git_sidebar.zig:53-65](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/git_sidebar.zig#L53-L65); tested in [experience_tests.zig:399](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L399); sampled in `zircon-dark-git.png` (hover fill, 0 primary pixels). |
| **Extension selection vs row/hover** | **Verified** | `Palette.applySelection()` in [theme.zig:25-30](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/theme.zig#L25-L30) derives distinct row/hover fills; tested in [settings_tests.zig](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/settings_tests.zig). |
| **Clickable path/Line breadcrumbs** | **Verified** | [chrome.zig:83-107](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L83-L107), [shell.zig:308-333](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig#L308-L333); path segments expand/reveal in tree; Line reveals cursor; tested in [workspace_polish_tests.zig:200](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L200). |
| **Indent guides** | **Verified** | [canvas.zig:126-138](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L126-L138); pixel inspection in `zircon-dark-editor.png` detects guide pixels at x=307 and x=341 (34px step, color `57, 62, 71`). |
| **Horizontal overflow & pane containment** | **Verified** | [view.zig:90](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L90), [canvas.zig:206-212](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L206-L212); tested across 4 split directions in [workspace_polish_tests.zig:36](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L36); 2,722 scrollbar pixels sampled in `zircon-dark-split.png`. |
| **Stronger light tokens** | **Verified** | [theme.zig:18](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/theme.zig#L18); [theme.zig:31](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/theme.zig#L31); contrast tested in [all.zig:679](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/tests/all.zig#L679) (ratio ≥ 3:1 against `#fafafa`). |
| **Native captures for menus, pickers, search, MD, completion** | **Verified** | All 35 PNGs present in `evidence/manifest.json`. Captures for workspace menu, split menu, font picker, theme picker, project search, markdown, and caret completion verified. |
| **Test suite pass record** | **Verified** | `check`, `test-settings-native` (57 native tests passed), Linux cross-build, ReleaseFast, SVG check documented. |
| **Markdown incremental streaming claims** | **Clarified** | Confirmed background coalesced generation parsing with layout and asset caching; not incremental event layout. |

---

## Parity inventory vs workflow quality

This review rates UI quality and existing project workflows. To prevent misinterpreting this 9/10 score as full feature equivalence with Zed, the following architectural gaps remain documented:

- **Dock system**: Zed supports left, right, and bottom dock panels (terminal, project, git, chat). Zircon switches a single left sidebar rail between modes.
- **Pane tree**: Zed supports arbitrary recursive N-ary pane trees. Zircon currently supports a primary/secondary split (in 4 directions).
- **Symbol breadcrumbs & folding**: Zed displays AST symbol hierarchies and fold chevrons in the gutter. Zircon implements file path and line location breadcrumbs.
- **LSP & editing breadth**: Full LSP code actions, rename, references, arbitrary Vim Ex grammar, and soft line wrapping are not yet present in Zircon.
