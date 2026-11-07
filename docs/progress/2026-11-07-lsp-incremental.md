# Incremental language synchronization

The language client now reads `textDocumentSync` and `positionEncoding` from the initialize result. It records full, incremental or disabled synchronization and recognizes UTF-8, UTF-16 and UTF-32 negotiation.

For ordinary insertion events, the client can send one UTF-16 incremental change instead of copying the entire document. The application language poller connects this path to the shared Shell `DocumentChange` queue when one event bridges the tracked server revision to the current revision. Deletions, replacements, multiple mappings, missing queue history and non-UTF-16 encodings deliberately fall back to a full snapshot until their coordinate conversion is implemented.

The fixture server and client suite cover incremental negotiation, insertion ranges and stale version refusal. Full editor checks and all 117 fresh native checks remain green. This is the first bounded incremental path; it does not yet remove all full-document LSP traffic or implement arbitrary position encodings.
