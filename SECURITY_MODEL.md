# Security model: zircon

Threat model used to prioritize security scan findings for this repository. It was written with the maintainer from the code. Facts marked *(maintainer)* came from the maintainer; the rest is read from the code. Edit it as the system changes.

## Maintainer priorities *(maintainer)*
- **Assets:** all assets weigh the same; none is ranked above the others.
- **Attackers:** all count. None is ruled out.
- **Out of scope:** `docs/`, `examples/`, `bench/` and tests (`test/`, `tests/`, `Tests/`, `*.test.*`, `*_test*`). Findings located only in those paths are not worth fixing. Production code that a test exercises stays in scope.

## Components

| Component | Code | Trust boundary |
|---|---|---|
| **zircon-editor** | `packages/**` (zircon_editor, zircon_ui, zircon_workspace, zircon_git, zircon_language, zircon_agent, zircon_search, zircon_markdown, ...), `apps/**` | Local native editor; opens untrusted files/repos; spawns git, LSP, agents |
| **zircon-extension-host** | `tools/zed-extension-host/**`, `packages/zircon_extensions/**` | Rust worker running Zed Wasm extensions (wasmtime/WASI) with `process:exec` capability checks; downloads from api.zed.dev |

## System, entry points, assets and attackers

Native Zig UI framework + text editor (macOS AppKit/CoreText/Metal; Linux builds only portable tests). Assets: user's files and machine. Entry points: files and repositories the user opens (parsers: text, markdown, git output, LSP JSON-RPC, agent JSONL), workspace persistence/recovery files, git subprocesses (argv, no shell), language servers, agent subprocesses (`zircon_agent/transport.zig`), Zed extensions via the extension host (wasmtime, preopened dirs, `process:exec` capability argument patterns, HTTPS catalog/download from Zed). Attackers: a malicious repository/file opened in the editor (command/argument injection into git/LSP, path traversal, memory-safety in parsers), a malicious or compromised extension escaping its capability set, a malicious agent/LSP response.

## Open questions
- Should developer tooling (`tools/` scripts other than the extension host) be treated as lower priority?
