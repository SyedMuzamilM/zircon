# Zircon native editor UI review — Gemini round 3

Reviewer: Gemini (independent review sub-agent).  
Target candidate: Zircon candidate `04269cc` (application source `2faf2bb`) in `/Users/syedmuzamilm/work/expirements/zigpui`.  
Installed reference: `/Applications/Zed Preview.app` version 1.28.0 (`arm64`, SHA-256 `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637`), fixture repository `EditorReview`.  
Evaluation rubrics: [rubric.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/rubric.md), [inspection.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/inspection.md), and [zed-extensions.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/zed-extensions.md).  
Evidence sets:
- Primary evidence: 39 PNG captures documented in [evidence/manifest.json](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/manifest.json) (10 Zed reference captures, 28 deterministic review captures across One Dark and One Light including 700 × 650 narrow layouts, and 1 native completion capture).
- Extension journey evidence: 7 PNG captures in [docs/reviews/extensions/evidence/](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/extensions/evidence/) (`extensions-catalog.png`, `extensions-installed.png`, `official-zig-theme-icons-wrap.png`, `official-zls-completion.png`, `python-pyright-completion.png`, `python-light-theme.png`, `markdown-code-wrap-light.png`).

---

## Independent evaluation statement & disclosures

1. **Independent scoring discipline**: This review and all category scores were independently established through direct analysis of the application source, automated test suites, and pixel-level evidence captures before consulting other round 3 reviews.
2. **Visual inspection methodology**: I inspected the codebase, test implementations, and evidence images using automated Python scripts to decode uncompressed RGBA pixel buffers, measure layout bounds, verify color values, and assess contrast ratios. I explicitly disclose that as an AI subagent operating in a text/tool environment, I lack interactive human eyesight and did not manipulate an interactive desktop window.
3. **Unverified behaviors**: Static screenshot captures and headless test harnesses cannot measure real-time input latency, 60/120 Hz animation fluidity, interactive multi-stage macOS IME candidate popups, or VoiceOver screen-reader accessibility.
4. **Validation disclosures**: Parent validation successfully executed `./tools/zig build check test-settings-native`, Linux test cross-compilation, `ReleaseFast` builds, icon/formatting checks, and the native extension journey (`tools/verify_zed_extensions.zig`). In accordance with review instructions, tests are evaluated as verified by the parent build pipeline and are not claimed to have been rerun by this subagent.
5. **Workflow quality vs full feature parity**: As established in [rubric.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/rubric.md), rubric scores evaluate the UI quality of existing workflows. Full Zed feature parity (integrated terminal dock, DAP interactive debugger, collaborative CRDT editing, arbitrary multi-directional pane trees, and semantic LSP refactorings) is accounted for separately in the parity inventory.

---

## Summary scores

| Category | Score | Summary rationale |
| :--- | :---: | :--- |
| **1. Visual hierarchy and geometry** | **1 / 2** | Clickable path/line breadcrumbs, 1px thin dividers with 5px hit targets, visible indent guides, adjacent tab border sharing, resizable sidebars, and clean narrow window containment (700 × 650) without status bar overlap are verified. Score remains 1/2 because breadcrumbs lack AST symbol navigation, the gutter reserves a 52px minimum without folding controls, and horizontal scroll thumbs remain visible-line bounded. |
| **2. Color and typography** | **2 / 2** | Text selection is distinctly separated from row focus (blue in dark mode, lavender in light mode); inactive split selection is muted; multiline selection bands terminate cleanly with visible newline cells; focused split exclusively paints the active line tint and bright line number; Markdown fenced code now inherits editor theme token colors in both light and dark modes; One Light syntax tokens maintain ≥ 3:1 WCAG contrast. |
| **3. Menus and controls** | **2 / 2** | Command palette features a 38px search header, 30px compact rows, undimmed editor backdrop, keyboard shortcut badges, and outside-click dismissal. In narrow windows (700px), palette width clamps up to 560px with 24px minimum insets, accommodating long command labels without clipping. Searchable font and theme pickers, caret-anchored completion with Up/Down keyboard control, and shared geometric corner radii (4px/6px/8px) are test-verified. |
| **4. Editor interactions** | **2 / 2** | Soft word wrapping with cached visual rows and visual-line caret navigation (`Option-Z`), auto-dot completion triggering real language servers on typing `.`, continuous multiline selection, macOS word/line deletion semantics, split focus click switching, and Vim modal editing (Normal/Insert/Visual with `/` search integration) are implemented and verified in tests. |
| **5. Existing project workflows** | **2 / 2** | Git commit button prerequisites (disabled when unstaged/conflicted/empty), branch switching, stashes, inline gutter hunk expansion, and inline blame with hover details and Copy SHA clipboard action are verified. Project search navigates matches while preserving state. Markdown preview renders cached structures, assets, and wrapped themed code. Settings modal provides live persistence and keybinding collision validation. Official Zed extension catalog browses 1,585+ packages with verified ZLS and Pyright sessions. |
| **Total** | **9 / 10** | **High UI quality across existing workflows against the rubric. Full Zed feature parity remains a separate inventory.** |

---

## 1. Visual hierarchy and geometry — 1 / 2

### Verified implementations
- **Narrow window containment (700 × 650)**:
  - In [zircon-dark-narrow-editor.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-narrow-editor.png) and [zircon-light-narrow-editor.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-narrow-editor.png), the full editor canvas fits cleanly above the 24px status bar.
  - Tested in [workspace_polish_tests.zig:240-270](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L240-L270) (`small windows keep editor canvases above the status bar`), asserting `primary.y + primary.height <= status.y + 0.1` down to 700 × 400 window dimensions.
- **Divider geometry and hit targets**:
  - Implemented in [view.zig:135-137](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L135-L137). Paints a 1px visible line (`colors.line`) centered within a 5px drag handle, with hover feedback (`colors.hover`).
  - Tested in [workspace_polish_tests.zig:12-34](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L12-L34), verifying that dragging the split divider resizes both editors without geometric drift.
- **Tab styling and adjacent borders**:
  - Implemented in [views/chrome.zig:34-40](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L34-L40). Eliminates doubled borders between adjacent tabs; active tab background blends into the editor surface; tab close chevrons match installed Zed Preview 1.28.0 styling.
- **Clickable path and line breadcrumbs**:
  - Implemented in [views/chrome.zig:83-107](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L83-L107) and [shell.zig:310-335](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig#L310-L335). Breadcrumbs render directory segments separated by right-chevron icons (`v.icon(b, .chevron_right, c.muted, 10)`). Clicking a folder reveals it in the project file tree; clicking `Line {d}` focuses the pane and reveals the cursor line.
  - In split mode, breadcrumb clicks reliably restore focus to the pane that owns the document ([workspace_polish_tests.zig:302-334](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L302-L334)).
- **Indent guides**:
  - Implemented in [canvas.zig:126-138](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L126-L138). Draws vertical 1px lines at tab-width intervals using `line_number` color at alpha 0.2, matching text indentation.
- **Sidebar resize flexibility**:
  - Tested in [workspace_polish_tests.zig:60-72](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L60-L72), allowing the project tree sidebar to shrink down to 120px while maintaining Git sidebar width independently.

### Concrete defects and within-rubric gaps
1. **Lack of AST/symbol breadcrumbs**: `fileHeader` displays only file path segments and line numbers (`src/main.zig › Line 5`), whereas installed Zed Preview 1.28.0 displays structural AST syntax symbols (e.g. [zed-dark-editor.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zed-dark-editor.png) shows `src/main.zig › pub Session struct`).
2. **Missing gutter folding chevrons**: Zed displays disclosure fold chevrons (`v` / `>`) in the gutter adjacent to collapsible syntactic blocks (e.g. lines 4, 15, 24 in `zed-dark-editor.png`). Zircon's gutter only displays line numbers and git change bars.
3. **Fixed 52px gutter minimum reservation**: Zircon's editor gutter reserves a fixed 52px minimum width (`gutterWidth` in [canvas.zig:42](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L42)), consuming excessive horizontal space in small narrow windows for single-digit line counts.
4. **Viewport-bounded horizontal scroll thumb**: The editor canvas horizontal scrollbar thumb calculates length based on visible lines rather than a global longest-line index.
- **Rubric effect**: Category 1 is rated **1 / 2** due to missing AST symbol breadcrumbs and the absence of gutter folding controls.

---

## 2. Color and typography — 2 / 2

### Verified implementations
- **Selection vs row focus distinction**:
  - Dark mode: Text selection is blue (`#3d5275` / `(62, 83, 118)`), row focus is neutral dark gray (`#3b414d` / `(59, 65, 77)`), active line background is `#2f343e` ([packages/zircon_editor/src/theme.zig:11-13](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/theme.zig#L11-L13)).
  - Light mode: Text selection is lavender (`#c6d2f5` / `(197, 209, 244)`), row focus is neutral light gray (`#e2e5ed` / `(226, 229, 237)`), active line background is `#eef1f5`.
  - Inactive split selection: Muted to `#33425a` (dark) and `#e0e5f1` (light).
  - Pixel inspection of [zircon-dark-selection.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-selection.png) confirms `(62, 83, 118)` fill; [zircon-light-selection.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-selection.png) confirms `(197, 209, 244)` fill.
- **Focused split active-line isolation**:
  - In [canvas.zig:122-125](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L122-L125), `cx.focused` exclusively gates `self.theme.active_line` background fill and `self.theme.active_number` line-number brightness:
    ```zig
    const is_active_line = cx.focused and row == primary_row;
    if (is_active_line) try self.paintActiveLine(cx, y);
    ```
  - Pixel sampling of [zircon-dark-split.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-split.png) confirms:
    - Left (unfocused) pane at cursor line (y=100..115): `(40, 44, 51)` (normal background, no active line tint).
    - Right (focused) pane at cursor line (y=100..115): `(47, 52, 62)` (`theme.active_line`).
  - Pixel sampling of [zircon-light-split.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-split.png) confirms:
    - Left pane: `(250, 250, 250)` (clean background).
    - Right pane: `(238, 241, 245)` (`theme.active_line`).
  - Tested in [workspace_polish_tests.zig:336-360](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L336-L360) (`only the focused split paints the active line and focus moves with a click`).
- **Markdown code theme token inheritance**:
  - In [shell.zig:250-254](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig#L250-L254), `previewColors()` binds `tokens = self.editor_options.theme.tokens`.
  - In [views/markdown.zig:17,449](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/markdown.zig#L17-L449), `tokenColor()` indexes directly into `colors.tokens[@backingInt(kind)]`.
  - Resolves the prior defect where light Markdown previews displayed dark pastel code colors. In [zircon-light-markdown-code-wrap.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-markdown-code-wrap.png), `const` matches `self.editor_options.theme.tokens[1]` (`#8a2f94`). Tested in [experience_tests.zig:820-850](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L820-L850).
- **Stronger One Light syntax contrast**:
  - In [packages/zircon_editor/src/theme.zig:18](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/theme.zig#L18), light syntax colors provide WCAG contrast ratio ≥ 3:1 against light background (`(250, 250, 250)`), verified in [all.zig:679-686](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/tests/all.zig#L679-L686).
- **Settings window initial styling**:
  - Propagates parent appearance during `openChildWindow` in [settings/view.zig:56-65](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/view.zig#L56-L65). Light settings queries initialize with `background.r >= 0.8` on first frame.

### Concrete limitations
- **Coarse 7-category token mapping**: Real Tree-sitter WASM grammars map AST captures into 7 broad token categories rather than full semantic token types/modifiers or granular TextMate scopes.
- **Font style limitations**: Token-level italics or bold font weights are not supported.
- **Rubric effect**: Rated **2 / 2** (Fulfills all rubric requirements for distinct text selection, active/inactive contrast, light/dark surfaces, readable icons, and text alignment).

---

## 3. Menus and controls — 2 / 2

### Verified implementations
- **Narrow window command palette expansion**:
  - In [view.zig:153](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L153), palette width is calculated as:
    ```zig
    const width = @min(if (self.overlay == .palette or self.overlay == .quick_open) @as(f32, 560) else 580, @max(0, b.viewport().width - 48));
    ```
  - In a 700px viewport, `width = 560px` with symmetric 70px side margins. Long command labels (such as "Extensions: install language support") fit on a single line without truncation or clipping.
  - Verified in [zircon-dark-narrow-commands.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-narrow-commands.png) and [zircon-light-narrow-commands.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-narrow-commands.png).
  - Tested in [workspace_polish_tests.zig:272-300](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L272-L300) (`narrow command palette gives long commands room and stays within the window`).
- **Command palette header and backdrop**:
  - Single search header with search icon, fixed 38px query height, 14px text size, and compact 30px item rows.
  - Backdrop scrim alpha is `0` for pickers ([view.zig:228](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L228)), ensuring underlying editor code remains legible in `zircon-dark-commands.png` and `zircon-light-commands.png`.
  - Outside-click dismissal ([shell.zig:334-342](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/shell.zig#L334-L342)) closes the palette without editing underlying buffers.
- **Searchable font and theme pickers**:
  - Implemented in [settings/view.zig:490-504](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/settings/view.zig#L490-L504). Features interactive query filtering, Up/Down arrow selection, Escape dismissal, and active selection checkmarks.
  - Evidenced in [zircon-dark-font-picker.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-font-picker.png) and [zircon-dark-theme-picker.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-theme-picker.png).
- **Anchored popovers**:
  - Split menu and workspace menu anchor directly below their trigger controls and clamp within window boundaries ([workspace_polish_tests.zig:182-198](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L182-L198)).
- **Caret-anchored completion popup**:
  - Anchors directly to committed text input caret coordinates ([view.zig:43-51](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/view.zig#L43-L51)). Supports keyboard arrow navigation, Enter/Tab acceptance, and Escape dismissal. Evidenced in [zircon-dark-completion.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-dark-completion.png) and [official-zls-completion.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/extensions/evidence/official-zls-completion.png).
- **Shared radii**:
  - Standardized metrics in [views/components.zig:8-10](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/components.zig#L8-L10): `control_radius = 4`, `popover_radius = 6`, `card_radius = 8`. Pill switches use circular endcaps (`height / 2`).

### Concrete limitations
- **Substring query filtering**: Command palette uses case-insensitive substring/prefix matching rather than fuzzy subsequence scoring (e.g. typing `wmt` for "Toggle Soft Wrap").
- **Rubric effect**: Rated **2 / 2**.

---

## 4. Editor interactions — 2 / 2

### Verified implementations
- **Soft word wrapping**:
  - Implemented in [packages/zircon_editor/src/wrap.zig](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/wrap.zig). Caches visual row segments per document line; tracks invalidation via incremental delta lines (`pending` tracking).
  - Toggled via `Option-Z` or Settings (`soft_wrap: "editor_width"`).
  - Vertical caret navigation (Up/Down) navigates across wrapped visual rows.
  - Horizontal scrollbar is suppressed when soft wrap is active.
  - Tested in [all.zig:690-750](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/tests/all.zig#L690-L750) and evidenced in [official-zig-theme-icons-wrap.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/extensions/evidence/official-zig-theme-icons-wrap.png).
- **Auto-dot completion trigger**:
  - Implemented in [actions.zig:303-307](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig#L303-L307): typing a single `.` immediately fires an LSP completion request to the active language server.
  - Evidenced in [tools/verify_zed_extensions.zig:168-175](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/verify_zed_extensions.zig#L168-L175) where typing `.` after `std.` triggers ZLS completions, accepted via Enter and verified in source text.
- **Continuous multiline selection**:
  - Implemented in [canvas.zig:145](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/canvas.zig#L145). Selection bands fill the full line height plus newline cell, preserving blank line visibility without overdrawing to the window edge.
- **macOS editing & deletion semantics**:
  - Native word deletion (`Option-Backspace`) and line deletion (`Cmd-Backspace`) handle multicursors, boundary conditions, and composition transactions cleanly.
- **Split focus switching**:
  - Clicking inside an unfocused split or clicking its breadcrumb header immediately transfers focus and active-line rendering ([workspace_polish_tests.zig:336-360](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L336-L360)).
- **Vim modal editing**:
  - Implemented in [packages/zircon_editor/src/vim.zig](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_editor/src/vim.zig). Supports Normal, Insert, and Visual modes; operators (`d`, `y`, `c`, `p`); block cursor in normal mode; `/` forward search integrating with the find overlay and returning to Normal mode on Escape ([workspace_polish_tests.zig:100-120](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/workspace_polish_tests.zig#L100-L120)).

### Concrete limitations & unverified behaviors
1. **Unicode / BiDi wrapping limits**: Word wrapping assumes uniform monospaced advances; complex multi-codepoint emoji sequences or right-to-left scripts lack ICU/HarfBuzz segmentation.
2. **No snippet completion expansion**: LSP completions containing snippet placeholders (e.g. `$1`, `${1:name}`) insert as raw text without interactive tab stops.
3. **Unverified runtime semantics**: Interactive 120Hz frame rates, foreground macOS IME composition candidate windows, and VoiceOver screen-reader integration cannot be verified from headless native tests or static captures.
- **Rubric effect**: Rated **2 / 2** (Existing workflow editor interactions are complete, robust, and verified).

---

## 5. Existing project workflows — 2 / 2

### Verified implementations
- **Git staging, review & repository controls**:
  - Staging/unstaging individual files; commit button prerequisites disable the button when no changes are staged, during background operations, or when the message is empty.
  - Branch creation and switching (`git_branches`) and stash management (`git_stashes`, stash pop) tested in [experience_tests.zig:740-800](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L740-L800).
  - Inline hunk expansion in gutter: clicking a gutter change bar expands removed lines inline with a soft red background without altering document dirty state or buffer selections ([experience_tests.zig:702-738](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L702-L738)).
  - Intraline diff highlighting balances matching runs.
- **Inline blame with hover details**:
  - Automatically activates after cursor idle delay; displays compact inline author text. Hovering the annotation reveals commit date, SHA, and commit message with a functional "Copy SHA" clipboard action ([experience_tests.zig:620-700](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L620-L700)).
- **Project search**:
  - Multi-file ripgrep search with query input, total match counts, and jump-to-match preserving search view state ([experience_tests.zig:580-610](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L580-L610)).
- **Markdown preview with code block wrapping**:
  - Implemented in [views/markdown.zig:270-305](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/markdown.zig#L270-L305). Preserves code block indentation, applies editor theme token colors, and wraps long identifier tokens inside the code block background without horizontal clipping.
  - Evidenced in [zircon-light-markdown-code-wrap.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/evidence/zircon-light-markdown-code-wrap.png) and tested in [experience_tests.zig:820-850](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/tests/experience_tests.zig#L820-L850).
- **Settings view & persistence**:
  - Dedicated window with live updates for theme, font size, tab width, line numbers, git gutters, and soft wrap; keybinding collision validation.
- **Official Zed extension catalog & WASM host**:
  - Official Zed registry search across 1,585+ extensions ([views/extensions.zig:120-190](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/extensions.zig#L120-L190)).
  - Downloads official extension bundles, runs WASM adapters, and supports install, update, disable, and remove workflows.
  - Suffix and filename install suggestions in [language_suggestions.zig](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/language_suggestions.zig).
  - Verified with real ZLS and Pyright sessions in [tools/verify_zed_extensions.zig](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/verify_zed_extensions.zig), evidenced in [extensions-catalog.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/extensions/evidence/extensions-catalog.png), [official-zls-completion.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/extensions/evidence/official-zls-completion.png), and [python-pyright-completion.png](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/extensions/evidence/python-pyright-completion.png).

### Concrete limitations
- **Missing LSP features**: No hover documentation tooltips, Go to Definition (`textDocument/definition`), Find References (`textDocument/references`), Rename Symbol, Formatting, or Code Actions. Only completion and diagnostics are wired to the editor canvas.
- **Process-based full-document re-parsing**: Extension host parses grammar spans with an 80ms debounce window and re-lexes whole documents rather than incremental syntax tree editing.
- **Rubric effect**: Rated **2 / 2** (Existing project workflows meet the rubric criteria).

---

## Parity gap inventory (Zircon vs Zed Preview 1.28.0)

The high rubric score reflects the refined execution of Zircon's **existing** workflows. As mandated by [rubric.md](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/zed-ui/rubric.md), full Zed feature parity is tracked separately:

| Feature Area | Installed Zed Preview 1.28.0 | Zircon Candidate `04269cc` / `2faf2bb` | Parity Status |
| :--- | :--- | :--- | :--- |
| **Integrated Terminal** | Multi-tab embedded Alacritty terminal dock with split panes | Not implemented | Missing |
| **Interactive Debugger** | Integrated DAP debugger with breakpoints, call stacks, variables | Not implemented | Missing |
| **Collaborative Editing** | Real-time multi-user CRDT channels, audio calls, screen sharing | Not implemented | Missing |
| **Workspace Panes** | Arbitrary N-ary split graphs (vertical/horizontal nesting) | Single split (primary and secondary pane) | Partial |
| **LSP Language Features** | Full LSP (Hover, Go-to-Def, Find References, Rename, Code Actions) | Completions and Diagnostics only | Partial |
| **Syntax Tree Parsing** | Incremental Tree-sitter C bindings updating AST on keystroke | Process-based WASM parser, 80ms inactivity debounce | Partial |
| **Breadcrumbs** | Structural AST symbol hierarchy (`path › struct › method`) | File path segments and cursor line number | Partial |
| **Gutter Controls** | Code folding chevrons (`v` / `>`) with collapsible scopes | Line numbers and Git change bars only | Partial |
| **Extension Catalog** | Full extension runtime with native extensions and Slash commands | Official registry catalog with WASM themes/icons/grammars/LSPs | Partial (documented limits) |
| **Fuzzy Search** | Subsequence fuzzy scoring with frequency ranking | Substring and prefix filtering | Partial |
