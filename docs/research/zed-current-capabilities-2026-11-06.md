# Current Zed capabilities for the Zircon audit

Retrieved 2026-11-06 from official Zed documentation source and `zed-industries/zed`. This is a source-and-documentation survey, not a runtime test or benchmark.

## Revision and evidence scope

- Audited upstream `main`: [`e231594b6b8818ea8d668ee2eb73e1fb09300654`][revision], committed 2026-11-06 14:35:38 UTC, subject "git: Add date format and per-view date style settings".
- GitHub's latest-release API returned [`v1.27.0`][release], published 2026-11-04 17:04:23 UTC. `git ls-remote` resolved that tag to `c84af5b99cbc366d675064e52b23664a015b6e35`. The findings below describe the audited main revision; they are **not a claim that every item ships in v1.27.0**.
- `https://zed.dev/docs` returned HTTP 403 to this retrieval. Official documentation was read from `docs/src` in Zed's own repository, pinned to the audited revision. These are actual official documentation files, not inferred descriptions of the code or a successful retrieval of the rendered website. Canonical documentation routes below identify the corresponding zed.dev pages.
- "Docs" means an explicit statement in those official documentation files. "Source" means implementation inspected at the pinned revision. "Inference" marks the researcher's conclusion. Source tests were inspected, not executed.
- No editor latency, memory, large-file, Git-refresh, search-throughput, or Zircon-versus-Zed measurements were performed. Rust, GPUI, incremental parsing, or GPU rendering alone do not establish performance superiority.

## Editing and language intelligence

Docs: [Editing code][d-edit], [multibuffers][d-multi], [Vim][d-vim], [Helix][d-helix], [visual customization][d-visual]. Canonical routes: [editing-code](https://zed.dev/docs/editing-code), [multibuffers](https://zed.dev/docs/multibuffers).

- Multi-cursor editing includes selecting the next occurrence and all matches. Multibuffers combine editable excerpts from multiple files, share edits with other open views, and save their underlying files. Project search, diagnostics, references, and multiple definition results can use this same editing model.
- Completion and snippet insertion, language-server rename/refactoring and code actions, formatting, and diagnostic feedback are documented workflows. Formatting can use language servers or configured external tools, with per-language format-on-save settings.
- Editor presentation includes syntax highlighting, folds, soft-wrap choices, whitespace indicators, indent guides, line numbers, configurable fonts/ligatures, rulers, and scrollbar/minimap settings. These are configurable features, not evidence of identical behavior for every script, language, or file size.
- Vim emulation includes motions, text objects, visual/block selections through multi-cursor, macros, and integration with navigation, Git hunks, and search. Docs explicitly say it does not replicate Vim one-to-one; regex syntax differs. Helix emulation builds on Vim mode and is explicitly a work in progress with missing bindings.

Docs: [Configuring languages][d-languages], [completions][d-completion], [diagnostics][d-diagnostics], [semantic tokens][d-semantic], [finding and navigating][d-find]. Canonical route: [configuring-languages](https://zed.dev/docs/configuring-languages).

- Tree-sitter provides syntax/structure features; LSP provides semantic completion, hover, definitions, type definitions, implementations, references, rename, code actions, workspace symbols, and diagnostics. Current navigation docs also describe incoming/outgoing call hierarchy.
- Zed manages language servers, including automatic downloads/updates for supported integrations. Users can choose, order, exclude, and configure servers per language and override binaries/settings. Support can be built in or supplied by an extension.
- Both push and pull LSP diagnostics are documented, with underlines, scrollbar markers, optional inline diagnostics, project-panel/tab indicators, and a diagnostics view. Semantic tokens can combine with Tree-sitter or replace its highlighting for supported buffers; they are **off by default** and changing mode may require restarting the server.
- Limits: language intelligence depends on the selected server, its capabilities, project configuration, and trust. For example, call hierarchy requires server support. The diagnostics page's broad compatibility wording should not be generalized into verified support for every LSP method or every server.

## Unicode, encodings, IME, and accessibility

Source: [Editor input][s-input], [editor tests][s-editor-tests], [line wrapping][s-wrap], [bidirectional layout][s-layout], [file decoding/encoding][s-content], [worktree reads/writes][s-worktree].

- IME is implemented. The editor exchanges UTF-16 selection/replacement ranges with platform input, tracks marked composition text, commits/unmarks it, groups composition transactions, and handles multi-cursor replacement. Source tests cover IME composition and macOS Accessibility Keyboard completion. Those are evidence of implementation and test coverage, not a live validation of every IME/OS combination.
- Grapheme-aware wrapping exists. The wrapper avoids breaking oversized grapheme clusters, with tests covering preservation of grapheme boundaries. Editor tests also cover multi-selection grapheme columns. Do not reduce this implementation to byte-only or ASCII-only editing.
- There is RTL-aware shaping/layout code and an RTL wrapping test. However, the layout source explicitly calls its handling a "Workaround for the lack of complete UAX #9 support" at [lines 252 onward][s-layout-rtl]. Full bidirectional editing, cursor movement, selection behavior, and mixed-script correctness were not established by this survey.
- Files are not restricted to UTF-8 on disk. Source uses `encoding_rs` and `chardetng`, BOM handling, UTF-16LE/BE, and legacy encoding detection/conversion. Buffers retain encoding/BOM metadata, can reload with a selected encoding, and encode on save. UTF-8 without a BOM has a streaming write path; legacy encodings currently convert the whole rope before writing. Inference: detection and re-encoding should not be advertised as lossless for arbitrary malformed bytes or characters unavailable in the target encoding. The encoding code discards some conversion-error flags.

Source: [Zed startup][s-startup], [GPUI accessibility guide][s-a11y], [accessibility tree implementation][s-a11y-tree], platform adapters for [macOS][s-a11y-mac], [Windows][s-a11y-win], [X11][s-a11y-x11], and [Wayland][s-a11y-wayland].

- GPUI contains AccessKit accessibility trees, roles/actions/focus handling, and platform adapters. Claiming that no accessibility implementation exists would be outdated.
- **Zed's application path is experimental and disabled by default.** `build_application` uses the accessible application constructor only when `ZED_EXPERIMENTAL_A11Y=1`; otherwise it calls `Application::new_inaccessible`. This source fact is stronger than inferring product readiness from the GPUI guide.
- GPUI's guide says nodes need IDs and nonempty roles to be exposed. Inference: framework infrastructure does not establish complete editor/widget coverage or screen-reader usability. This survey did not verify VoiceOver, NVDA, Orca, Braille, or complete editable-text semantics. Font/theme customization and macOS Accessibility Keyboard input are distinct from full screen-reader support.

## File watching and external modifications

Source: [Filesystem watchers][s-watch], [worktree scanning][s-worktree], [buffer file updates/conflicts][s-buffer], [project reload handling][s-project], [save prompts][s-pane], [autosave eligibility][s-item].

- Watchers feed worktree scanning, entry updates, and repository updates. Source distinguishes recursive native watches on macOS/Windows from per-directory native Linux watches and recursive polling.
- Automatic filesystem-type detection selects polling for affected Linux filesystems, with source comments naming 9P/WSL drvfs, NFS, SMB/CIFS, and FUSE. `ZED_FILE_WATCHER_MODE=auto|native|poll` can override selection. Watch registrations include retry/recovery handling. This is not a guarantee that all network filesystems deliver correct events.
- A previously clean buffer whose disk state changes to a present file emits `ReloadNeeded`; the project reloads it automatically unless it is a collaboration guest path. A dirty buffer does not take that clean-buffer reload path.
- `Buffer::has_conflict` detects unsaved local edits plus a disk mtime newer than the saved mtime, or an explicitly marked conflict. Ordinary saving presents **Overwrite / Discard Edits / Cancel**. Discard reloads from disk. Autosave eligibility excludes conflicting items. Explicit overwrite/save-as paths have different semantics, so "Zed can never overwrite external changes" would be too strong.
- Inference: external-change detection is asynchronous and depends on watcher/scanner state and metadata. This inspection does not establish content-hash race protection, guaranteed refresh deadlines, or lossless merging of simultaneous disk and buffer edits. Disk-save conflicts here are separate from Git merge conflicts.

## Git, history, conflicts, and refresh

Docs: [Git][d-git], [tasks and Git Graph commands][d-tasks]. Canonical route: [git](https://zed.dev/docs/git). Source: [Git graph][s-graph], [Git store][s-git-store], [conflict view][s-conflict], [repository watcher handling][s-worktree].

- The Git panel shows repository/branch, changed files, tracked/untracked groups, and staged state, with flat/tree layouts and configurable docking. Gutter change indicators and inline blame are configurable.
- Project Diff uses editable file excerpts. It supports whole-file and per-hunk staging/unstaging. Word-level change highlighting is configurable. **Split/side-by-side is the documented default**, with unified mode available. Docs say this preference also applies to File History and Stash Diff View.
- Commit UI includes a panel message editor, an expanded editor, and uncommit via soft reset. The documented panel workflow can auto-stage tracked files when committing, so an audit should check the actual staged-state workflow instead of assuming every commit requires explicit staging.
- File History lists commits for a file and opens a diff limited to that file's changes. The source also has a registered Git Graph view and file-history integration. Task docs describe custom Git Graph commit-context commands; these currently require global task definitions, not worktree-local ones.
- Built-in operations include fetch/push/pull, multiple-remote selection, branch creation/switch/deletion, lightweight tags at HEAD, and stash creation/view/apply/pop/drop. Tags are created locally and are not automatically pushed.
- Linked Git worktree creation, switching, opening in a new window, and deletion are documented, including multi-root handling and setup-task hooks. New worktrees start detached; the user can then choose an available branch.
- Merge-conflict UI marks regions and offers either branch or both, removes markers for the chosen content, and permits manual editing. Files must then be staged and the merge committed. These controls do not prove a general three-pane merge engine or complete support for every rebase/cherry-pick workflow.
- Docs say command-line Git changes are reflected "immediately" or "instantly". Source supports event-driven refresh: worktree scanning watches repository/common Git directories, refs and reftable paths, classifies metadata events, and requests Git-state reloads. A rescan event reloads affected repositories after watcher loss of synchronization. Git Store observes worktree-entry/repository updates and refreshes diff bases. This establishes a refresh mechanism, not a measured zero-latency guarantee.
- Repository activation can be deferred. In a repository-rooted project, repositories are active immediately. Outside that case, deeper repositories can wait until a file is opened; discovery also depends on scan depth. Docs explicitly recommend the terminal for Git operations not supported natively. Do not describe the UI as implementing every Git command.

## Search and navigation

Docs: [Finding and navigating][d-find], [multibuffers][d-multi], [scan-depth setting][d-settings]. Source: [search controls][s-search-ui], [project search queries][s-search-query].

- File finder filters project paths; text finder offers a compact project-text picker; project search presents editable results in a multibuffer. Command palette, current-file outline, project symbols, definitions/references, call hierarchy, and recent-tab switching cover separate navigation needs.
- Buffer/project search has literal/regex, case-sensitive, whole-word, include-ignored, and include/exclude-path controls. Buffer search includes selection scope; project UI includes replacement. Source uses `fancy_regex` for regex queries. Do not infer exact PCRE, ripgrep CLI, or Vim-regex compatibility from "regex support".
- The documented `file_scan_depth` default is **5** outside Git repositories. Unindexed deferred directories are invisible to file finder and project search until loaded. `0` eagerly indexes everything; repository-rooted trees are fully indexed regardless of this limit. Ignored-directory and explicit scan-inclusion/exclusion behavior also affects coverage.
- Inference: "searches the entire disk" or "every project file is always searchable" would be inaccurate without accounting for ignore settings, scan exclusions, and deferred indexing.

## UI, workspace, and panels

Docs: [Windows and projects][d-windows-projects], [parallel agents/layout][d-parallel], [visual customization][d-visual], [project panel][d-project-panel].

- Multiple projects can live in one window's Threads Sidebar. Current docs say opening folders normally adds a project to that window; `zed -n` and settings allow separate windows. Each project keeps its own tree, Git state, search scope, and split/tab layout.
- A project can have multiple root folders. Do not confuse several independent projects in the sidebar with one multi-root project.
- Classic and Agentic panel-layout actions rearrange the editor/agent workspace. Individual panels can be moved; configurable left/right/bottom docks include project, Git, terminal, outline, collaboration, and agent workflows.
- Project-panel file operations include create/rename/move/delete, with Git/diagnostic decorations. UI customization includes themes, icon themes, fonts, keybindings, tab/status/title-bar controls, wrapping, and pane styling.
- Inference: this is a native GPUI editor/workspace with specialized panels. It is not evidence that extensions can create arbitrary VS Code-style webviews or replace all UI components.

## Terminal, tasks, debugging, and REPL

Docs: [Terminal][d-terminal], [tasks][d-tasks], [debugger][d-debugger], [REPL][d-repl]. Canonical routes: [terminal](https://zed.dev/docs/terminal), [debugger](https://zed.dev/docs/debugger).

- Built-in terminals can occupy a dock or the editor center, with multiple tabs/splits, configurable shells/cwd/environment, virtualenv activation, search, vi mode, clickable file paths/line numbers, and appearance controls.
- Tasks run shell commands in integrated terminals, using global or project `tasks.json`, task/context variables, rerun controls, inline language runnables, and temporary oneshot commands. Docs describe importing VS Code task definitions and a `create_worktree` hook. This is not a claim of full VS Code task-engine compatibility.
- Zed implements a DAP client with breakpoints, stepping, variable inspection, launch/attach configurations, and pre-debug build tasks. Configurations use `.zed/debug.json`; docs also cover VS Code launch configuration integration. Inline variable values are configurable.
- Available documented adapters cover built-in C/C++, Go, JavaScript/TypeScript, PHP, Python, Rust, and extension-provided Java, Ruby, Swift. Adapter capability determines actual behavior. The debug configuration comment says the attach process picker is currently Node-only.
- Jupyter-kernel REPL runs code inline in regular source files and Markdown, including script cells. Docs list Python, TypeScript/Deno, R, Julia, and Scala. Kernels must be installed; this does not establish a full Jupyter notebook application.

## Remote development and collaboration

Docs: [Remote development][d-remote], [dev containers][d-containers], [collaboration overview][d-collab], [channels][d-channels], [contacts][d-contacts].

- SSH remote development keeps the UI local while remote tooling handles files/language services/terminal work. Documented remote-server platforms include macOS, Linux x86_64/arm64, and Windows x86_64/arm64. Windows clients support SSH and native WSL folder opening. Port forwarding, remote settings, proxy configuration, server upload, reconnection, and restoration of unsaved changes are documented.
- Explicit remote limitations: no 32-bit Linux server support; opening very large directories such as `/` or homes with over 100,000 files is documented as problematic; typing `zed` in the remote terminal cannot open remote files. These are documentation limits, not measurements from this audit.
- Dev Containers use `.devcontainer/devcontainer.json` with Docker or Podman, running tasks, terminals, and language servers in the container. The feature is still described as in development. Configuration edits **do not automatically rebuild/reload** the container; manual stop/reopen is documented.
- Collaboration provides live shared editing/cursors, project sharing, channels/private calls, voice, screen sharing, collaborative Markdown notes, and pane-specific follow mode. Collaborators can edit/save/search and use language-server features; guests are read-only until granted write access.
- Collaboration requires sign-in. Sharing grants access within the shared project; it is not simply streamed pixels. Contacts docs specify GitHub-authenticated Zed users. Terminal following is explicitly not supported like editor following; screen sharing is the documented workaround.
- Inference: SSH remote development and hosted multiplayer collaboration are separate capabilities and trust models.

## AI, extensions, and platforms

Docs: [AI overview][d-ai], [agent paths][d-agents], [external agents][d-external], [parallel agents][d-parallel], [model access][d-providers], [API providers][d-api], [local models][d-local], [gateways][d-gateways], [edit prediction][d-prediction].

- Three distinct paths exist: Zed Agent with native tools/profiles/instructions/skills/MCP, external ACP agents in the agent UI, and CLI/TUI Terminal Threads. ACP registry examples include Claude, Codex, OpenCode, Copilot, Cursor, Pi, and Gemini CLI. External agents generally own authentication, model choice, configuration, and provider billing.
- Independent concurrent threads appear under projects in the sidebar; linked Git worktrees can isolate edits. Thread import depends on agent support, with Cursor and Gemini CLI named as unsupported in the inspected parallel-agent docs.
- Zed-owned AI features include agentic editing, Inline Assistant transformations, edit prediction, and commit-message generation. Model access can use Zed-hosted billing, provider APIs/subscriptions, gateways such as OpenRouter/Bedrock/Vercel, or local/self-hosted llama.cpp, Ollama, LM Studio, and compatible servers.
- First-class API docs list Anthropic, OpenAI, Google AI, Mistral, DeepSeek, xAI, OpenCode, and compatible endpoints. Edit prediction has **separate provider configuration**, including Zeta, Copilot, Mercury, Codestral, Ollama, and compatible self-hosted endpoints. Model/tool/image/context support varies by provider/model.
- [Privacy docs][d-privacy] distinguish Zed's retention from upstream-provider retention and optional training/feedback sharing. They explicitly contain exceptions for provider-designated safety-retention models. Do not summarize them as unconditional zero retention for all AI paths.
- [Sandbox docs][d-sandbox] restrict the scope to Zed Agent's terminal/fetch tools, with platform prerequisites and weaker Windows cases. This does not sandbox the whole editor, ordinary tasks/terminals, LSPs, extensions, external agents, or Terminal Threads. [Worktree trust][d-trust] gates project configuration and code-running integrations, with documented exceptions for globally trusted tools.

Docs: [Developing extensions][d-extensions], [capability restrictions][d-capabilities], [agent-server extensions][d-agent-extensions].

- Extensions provide languages/grammars/LSP integration, debuggers, themes, icon themes, snippets, and MCP servers. Procedural extension code uses Rust compiled to WebAssembly; declarative extensions need no Rust. The current build target is `wasm32-wasip2`.
- Execution/download/npm-install capabilities can be restricted. Host APIs and compatible Zed versions constrain extensions. Inference: this is a specific extension API, not proof of compatibility with arbitrary VS Code extensions.
- ACP agent-server extensions are documented as deprecated since v1.5.0 in favor of the ACP Registry. Keep agent distribution separate from language/theme/MCP extension capabilities.

Docs: [macOS][d-macos], [Linux][d-linux], [Windows][d-windows].

- macOS requires 12.0 or later on Apple Silicon/Intel and uses Metal. Linux official binaries target x86_64/aarch64, with Vulkan-compatible GPU and documented glibc requirements, 2.31 and 2.35 respectively. Other distributions/architectures can require source builds or compatibility layers.
- Windows has stable/preview builds, installer/winget instructions, SSH/WSL support, and a documented DirectX 11-compatible GPU requirement.
- Platform adapters or GPUI targets in source do not establish an officially supported browser/mobile Zed product. This survey verified desktop docs only.

## Audit implications

Treat the current upstream as a broad editor/IDE baseline with multibuffers, LSP, editable split/unified diffs, hunk staging, file history, Git refresh, DAP, remote work, collaboration, and several agent paths. Older claims that these features are absent need revision.

Retain explicit caveats for default-disabled experimental accessibility, incomplete UAX #9 handling, per-server/per-adapter capabilities, indexed-search scope, asynchronous watchers, dev-container reloads, and unsupported Git operations. Compare Zircon using reproducible workflows and the exact Zed binary version. This report provides a capability inventory and implementation evidence; it provides no performance ranking.

## Primary references

All repository links below are pinned to the audited main revision unless identified as the release link. Official docs are under `docs/src`.

[revision]: https://github.com/zed-industries/zed/commit/e231594b6b8818ea8d668ee2eb73e1fb09300654
[release]: https://github.com/zed-industries/zed/releases/tag/v1.27.0
[d-edit]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/editing-code.md
[d-multi]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/multibuffers.md
[d-vim]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/vim.md
[d-helix]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/helix.md
[d-visual]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/visual-customization.md
[d-languages]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/configuring-languages.md
[d-completion]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/completions.md
[d-diagnostics]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/diagnostics.md
[d-semantic]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/semantic-tokens.md
[d-find]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/finding-navigating.md
[d-git]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/git.md
[d-tasks]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/tasks.md
[d-settings]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/reference/all-settings.md
[d-windows-projects]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/windows-and-projects.md
[d-project-panel]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/project-panel.md
[d-parallel]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/parallel-agents.md
[d-terminal]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/terminal.md
[d-debugger]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/debugger.md
[d-repl]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/repl.md
[d-remote]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/remote-development.md
[d-containers]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/dev-containers.md
[d-collab]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/collaboration/overview.md
[d-channels]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/collaboration/channels.md
[d-contacts]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/collaboration/contacts-and-private-calls.md
[d-ai]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/overview.md
[d-agents]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/agents.md
[d-external]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/external-agents.md
[d-providers]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/llm-providers.md
[d-api]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/use-api-access.md
[d-local]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/use-a-local-model.md
[d-gateways]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/use-a-gateway.md
[d-prediction]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/edit-prediction.md
[d-privacy]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/privacy-and-security.md
[d-sandbox]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/ai/sandboxing.md
[d-trust]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/worktree-trust.md
[d-extensions]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/extensions/developing-extensions.md
[d-capabilities]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/extensions/capabilities.md
[d-agent-extensions]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/extensions/agent-servers.md
[d-macos]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/macos.md
[d-linux]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/linux.md
[d-windows]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/docs/src/windows.md
[s-input]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/editor/src/input.rs#L2798
[s-editor-tests]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/editor/src/editor_tests.rs#L469
[s-wrap]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui/src/text_system/line_wrapper.rs#L110
[s-layout]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui/src/text_system/line_layout.rs
[s-layout-rtl]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui/src/text_system/line_layout.rs#L252
[s-content]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/file_content/src/file_content.rs
[s-worktree]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/worktree/src/worktree.rs
[s-startup]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/zed/src/main.rs#L87
[s-a11y]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui/src/_accessibility.rs
[s-a11y-tree]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui/src/window/a11y.rs
[s-a11y-mac]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui_macos/src/window.rs#L2406
[s-a11y-win]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui_windows/src/window.rs#L1082
[s-a11y-x11]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui_linux/src/linux/x11/window.rs#L1988
[s-a11y-wayland]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/gpui_linux/src/linux/wayland/window.rs#L2256
[s-watch]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/fs/src/fs_watcher.rs#L283
[s-buffer]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/language/src/buffer.rs#L1796
[s-project]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/project/src/project.rs#L4130
[s-pane]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/workspace/src/pane.rs#L2256
[s-item]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/workspace/src/item.rs#L588
[s-graph]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/git_ui/src/git_graph.rs#L1083
[s-git-store]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/project/src/git_store.rs#L2390
[s-conflict]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/git_ui/src/conflict_view.rs
[s-search-ui]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/search/src/search.rs#L73
[s-search-query]: https://github.com/zed-industries/zed/blob/e231594b6b8818ea8d668ee2eb73e1fb09300654/crates/project/src/search.rs
