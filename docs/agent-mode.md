# Agent workspace and test build

Agent features are temporarily removed from the application. Provider startup, agent controls, shortcuts and settings are disabled. The material below records the earlier implementation for future work.

Build the native macOS package with `./tools/zig build package -Doptimize=ReleaseFast`. Open `artifacts/Zircon.app`, or extract `artifacts/Zircon-macos-arm64.zip` and drag the app to Applications. The bundle is locally signed for testing and includes the Zed extension worker. It is not a notarized release.

## Try the editor and extensions

Open a project with Shift-Command-O. Open Extensions from the status bar or command palette, choose All Zed extensions, and install a package. Theme/icon variants appear in Settings; language packages start supported servers for matching files. See [extension compatibility](zed-extensions.md) for supported APIs and prerequisites.

Command-/ toggles comments on the current or selected lines. Vim supports `gcc`, counted `gcc`, `gc` followed by a supported motion, and Visual `gc`. These use installed language comment delimiters, preserve indentation/multiple cursors and use normal undo. Markdown has HTML block comments. A selection ending at the next line start excludes that line.

## Open agent mode

Press Shift-Command-J or choose Agent: toggle workspace. Select a provider, create a conversation and Connect. Enter sends; Shift-Enter adds a line. The plus button attaches the current editor selection or file. The right pane opens files and the existing combined Git change review. Agent edits reload clean buffers after a turn; unsaved buffers remain protected by the workspace's existing policy.

Conversations stream text and tool activity, expose permission choices and can be stopped. New conversations retain independent drafts. History is saved per project under `~/Library/Application Support/Zircon/agent-history/`. Reconnect resumes Codex threads or ACP sessions when the provider advertises session loading. An agent without loading support reports that limitation; create a new conversation instead.

Provider/model pickers support filtering and keyboard navigation. Modern ACP configuration also exposes agent modes and reasoning levels when advertised. Codex currently exposes model selection; its other options retain the CLI defaults. The conversation view follows new output until scrolled and renders at most 256 KiB of recent content. Open saved conversation displays the complete JSON transcript in the editor. Transcript rendering coalesces running updates every 80 ms and reuses Markdown layout; no latency benchmark is claimed.

## Subscription logins

Zircon launches installed CLIs and inherits their authentication. It does not exchange subscription credentials for API keys.

- Codex: run `codex login`, then use the Codex provider. It runs `codex app-server` and uses its native thread/turn protocol.
- OpenCode: complete `opencode auth login` for your provider, then use OpenCode. It runs `opencode acp`.
- Gemini: install and authenticate Gemini CLI, then use Gemini. Its default command is `gemini --experimental-acp`. Gemini is not installed on the development machine, so its live login/turn flow remains unverified.

Native startup adds common Homebrew, Bun, local and Vite Plus binary directories to the child PATH. Configure an absolute command path for other installations.

## Your CLI proxy

The configured profile is **CLI Proxy**, via OpenCode ACP. Its API base is `http://127.0.0.1:8317/v1`. Authenticated discovery returned 15 model IDs on 2026-11-06. The native verification initialized that profile and found all 15 without sending a paid/model prompt.

Managed files on this machine:

- `~/Library/Application Support/Zircon/agents.json`: provider launch settings.
- `~/Library/Application Support/Zircon/proxy-opencode.json`: this proxy's OpenCode provider/model definitions, with `{env:CLIPROXY_API_KEY}` in place of a key.
- `~/Library/Application Support/Zircon/secrets/cli-proxy.key`: raw credential, mode 0600 inside a mode 0700 directory. This is a private local file, not encrypted storage or a repository asset.

The agent command **Configure providers** opens `agents.json`. **Agent: reload provider configuration** applies saved changes. Existing running conversations retain their process; new connections use updated settings.

Example provider entry, with paths adjusted for your account:

```json
{
  "name": "CLI Proxy",
  "protocol": "acp",
  "command": "opencode",
  "args": ["acp"],
  "env": { "OPENCODE_CONFIG": "/absolute/path/proxy-opencode.json" },
  "secret_env": { "CLIPROXY_API_KEY": "/absolute/private/path/cli-proxy.key" }
}
```

`env` contains explicit child environment overrides. `env_from` maps child variable names to existing environment variable names. `secret_env` maps child variable names to local credential files. These settings are read from the user's global Zircon configuration, never automatically from a repository.

OpenCode's custom provider uses `@ai-sdk/openai-compatible`, the proxy base URL and a models map. Model discovery populated that map during setup. Edit it to add models exposed later by your proxy. Only models supporting chat and tools are useful as coding agents; image-only endpoints appearing in a proxy catalog are not certified by this integration.

## Verified scope and limits

Portable and native tests exercise a real fixture agent: multiline composition, streamed Unicode, permission display, approval-gated writes, rejection, cancellation and history reopening. Installed Codex initializes with nine models; installed OpenCode exposes 775 models plus its advertised mode/reasoning options. The real native proxy profile loads its separate credential file and exposes 15 proxy models. These connection checks send no model prompt and do not certify every remote model or subscription tier.

This is a native agent workspace inspired by T3 Code, not full T3 Code parity. It does not yet implement delegated agent graphs, isolated Git worktrees per conversation, scheduled runs, image attachments, rich interactive tool output, ACP client terminals/filesystem RPC, every agent question/elicitation schema, or all authentication flows. Unsupported client requests receive errors. The header can copy the last agent response. Conversation Markdown has no text selection UI; the saved transcript can be opened, selected and copied in the editor. An agent CLI can run its own tools under its permissions; Zircon does not add an OS sandbox to arbitrary ACP agents. Codex starts with workspace-write and on-request approvals.

## Sources inspected

- [Codex app-server](https://developers.openai.com/codex/app-server/), fetched 2026-11-06; the installed CLI's generated JSON schemas also validated requests.
- [ACP protocol overview](https://agentclientprotocol.com/protocol/overview).
- [OpenCode ACP](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/acp.mdx), [configuration](https://opencode.ai/docs/config/) and [providers](https://opencode.ai/docs/providers/).
- [Zed agent server implementation](https://github.com/zed-industries/zed/tree/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/crates/agent_servers) and its ACP adapters. Zed separates provider connections from thread presentation; Zircon uses a portable protocol package and native workspace UI.
- [T3 Code](https://github.com/pingdotgg/t3code/tree/6577c6b6185167c0e502fa01f9e8e8f2dee6ff25), including its provider adapter structure and Codex app-server adapter. The protocol implementation was written in Zig; T3 Code is not bundled.
