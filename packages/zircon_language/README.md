# Zircon language client

UI-independent stdio JSON-RPC/LSP transport. `Client.start(allocator, io, Config)` creates a stable owned client. Config supplies executable, arguments, working directory and an optional thread-safe wake callback. Only its creating thread calls document/request methods or destroys the client. Transport threads own message arenas and never borrow UI entities.

Wait for `ready()` before `didOpen(uri, language_id, snapshot)`. `didChange` requires a newer revision; `didClose` releases the document identity. `completion(uri, revision, Position)` returns a server-local request ID. `cancel(id)` removes its pending identity and sends cancellation. `drain(allocator)` moves owned messages to the caller; release them with `deinitMessages`. Wake only signals that the owner should drain.

Messages include initialization, diagnostics, completion, logs, failures and exit. Completions carry request, URI and revision. Hosts must also associate the server session/caret, validate the document, convert UTF-16 ranges against the exact snapshot and apply edits in one transaction. The Zircon host checks those identities, rejects snippets and ignores unversioned diagnostics. `positionAt`, `offsetAt` and `fileUri` provide conversion and escaping.

Framing accepts fragmented headers/bodies and multiple messages. Bodies are limited to 8 MiB, headers to 8 KiB, outgoing/incoming queues to 16 MiB, inbound messages to 1,024, stderr capture to 64 KiB and completion/diagnostic items to 10,000. These bounds do not cap process memory. Unknown server requests receive Method not found. Workspace edits, progress UI, semantic tokens, rename, hover and formatting are not implemented.

Deinitialization sends document-close notifications and attempts shutdown/exit. An unresponsive owned child is killed, timed pipe loops stop, readers/writer join and resources are released. Cooperative cancellation alone cannot interrupt a blocked pipe read. Failures remain messages/errors; the package does not invent diagnostics or completions.

`./tools/zig build test-language` runs deterministic Python subprocess fixtures, including fragmented messages, reversed replies, stderr pressure, malformed output and blocked shutdown. `./tools/zig build test-language-real` separately accepts an installed Apple clangd completion through the macOS app. Native wake events avoid a permanent idle polling timer.
