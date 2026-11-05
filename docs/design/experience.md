# Extended editor implementation design

The controlling experience requirements and screenshot references are preserved in [editor-experience.md](../specification/editor-experience.md). Both design candidates were reviewed. Both used the inherited model; no cross-family judge was configured.

## Synthesis and module ownership

Use independent protocol/data packages from candidate B, with thin UI-owned service entities from A where multiple windows need shared effective state. Settings and extension activation have one application-owned identity. Repository/search results remain owned worker outputs installed only after generation/revision checks. No package that parses Git, manifests, Markdown or JSON-RPC imports the UI framework.

- `zircon_ui` owns integrated macOS chrome, drag regions, parent/child windows, images/texture lifetimes and native wake operations.
- `zircon_extensions` owns validated local contribution packages, enable/disable/install/remove, theme/icon/language/server resolution and persistent activation.
- `zircon_git` owns system Git commands, typed status/diff/history/blame and explicit mutations. The app serializes mutations and refreshes query state afterward.
- `zircon_search` owns grouped snapshot/disk matching. Open buffers override disk; stamps protect result activation/editing.
- `zircon_language` owns live stdio JSON-RPC, process lifetime, document versions, diagnostics/completion and UTF-16 conversion.
- `zircon_markdown` owns source-ranged parsing. Native preview layout uses Zircon UI text/images.
- `apps/zircon/services` and `views` join these capabilities into settings, extension manager, Git/search panels, image/preview tabs and workspace interaction.

## Core contracts

Integrated windows retain native titled/closable/resizable/fullscreen behavior and traffic lights, use full-size content views with hidden title/transparent titlebar, and expose designated committed drag regions. Controls/text remain ordinary hit targets. Settings opens in a child window above its workspace and watches shared settings. Candidate B's atomic-before-effective persistence policy is accepted: validate/write a candidate before publishing new effective values; failure retains the previous values and a recoverable error. Expose only settings with working behavior.

Local versioned JSON extensions contribute actual theme/token colors, icon mappings/assets, lexical definitions/file associations and server executable/argv. This is a constrained contribution system, not Zed/WASM compatibility. Validate paths/IDs/duplicates/limits. Install through a staged managed directory, resolve a complete candidate, then atomically activate. Disabling selects deterministic fallbacks and stops affected server sessions. No fabricated marketplace metadata.

Finite Git commands use argument arrays, bounded output and timeouts. Parse NUL-delimited status paths. Preserve prior state on failed queries/mutations. Panel stage/unstage acts on disk/index and labels unsaved buffers. Gutters compare captured unsaved text to an index baseline; results carry document revision. Blame uses captured contents and occupies real editor visual space when expanded. History/commit views show the requested commit's data.

Search captures retained immutable open-buffer snapshots before launching, and canonical paths prevent duplicate disk matches. Results retain source identity/revision or disk stamp, match byte ranges and context. Excerpt editing routes revisioned operations to the real document, never a disposable copied search buffer. Show truncation and unsupported query modes explicitly.

Pane dragging owns stable IDs, a capture session, movement threshold and valid drop zones. Prepare allocations before moving ownership. Cancellation leaves topology/documents intact. Images retain decoded immutable RGBA outside frame copies; Metal caches textures and retains submitted resources through completion. Markdown preview retains source ranges and uses the same framework renderer, with relative local images and explicit link actions.

LSP uses persistent piped processes, bounded Content-Length frames, serialized writes and owned inbound messages. UI recipient identities are generational. Native wake support prevents permanent idle polling. Closing pipes/killing only the owned child and joining readers is required because cooperative cancellation cannot unblock a pipe read. Apply completion edits only against their request revision. Fixture protocol tests precede real-server acceptance.

## Delivery and verification

Preserve the verified core/editor checkpoint first. Then implement integrated chrome/settings and local contribution activation, independent Git/search/image packages, real panels/gutters/blame/multi-buffer views, pane interaction and Markdown, and live language services. Every stage retains prior checks. Use real temporary repositories, extension directories, files, image pixels and protocol fixture processes; then drive native UI journeys and inspect rendered artifacts. New screens are not evidence of working integrations.
