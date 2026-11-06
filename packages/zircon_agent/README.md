# zircon_agent

Portable Codex app-server and Agent Client Protocol clients, independent of native UI.

`Conversation.connect()` starts one owned CLI process. `prompt()`, `cancel()`, `chooseModel()` and `answer()` drive its session. Call `poll()` on the owner thread to consume updates; transport threads parse bounded JSONL and publish owned messages. Optional `Wake` notifies a native event loop without borrowing UI state.

The client supports ACP v1 session setup/load, streaming text, tool activity, permission options, model configuration and modern mode/reasoning options. Codex uses native app-server threads, model listing, turns, text/output deltas and command/file approval responses. Unknown client requests receive an explicit unsupported-method response. Client-owned filesystem/terminal capabilities are advertised as unavailable; the agent runs its own tools.

`disconnect()` stops the owned connection and joins transport threads. Messages, queues and transcripts have explicit size limits. Provider credentials stay with their CLIs or caller-supplied environment. Conversation history and rendering are host concerns.

Run `./tools/zig build test-agent` from the repository root. Tests launch real fixture subprocesses and assert Unicode streaming, fragmented framing, permission-gated file writes, rejection and cancellation. `verify-agent-connections` optionally initializes installed Codex/OpenCode without sending model prompts.
