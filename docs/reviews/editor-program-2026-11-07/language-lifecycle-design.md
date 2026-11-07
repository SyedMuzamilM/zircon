# Language-selection lifecycle design

Two independent inherited-model design readers inspected the current service/pane ownership. Both confirmed the global teardown and rejected the alleged secondary-tab omission. These are design candidates, not implemented changes.

Candidate A introduces `invalidateDocument(document_id)` in the language service. It closes only that document, clears its completion/diagnostics, increments a document configuration epoch for grammar jobs, and binds the changed document to a fresh scoped server session. Unrelated shared sessions remain alive. Retired session entries retain stable indices for asynchronous resolver callbacks. Fresh target-session identity rejects late old-language diagnostics even when they are unversioned or reuse the same text revision. The cost is another server process for a manually rebound document.

Candidate B makes polling reconcile retained language/configuration identity for every open document. It catches future language-change origins without a picker-specific reset, but needs a broader binding model and ownership changes. Reusing the same client and URI at the same source revision cannot distinguish late previous-language diagnostics. Separate monotonic protocol versions solve versioned responses; unversioned freshness remains unknown.

The smaller immediate boundary is A. B belongs with TEXT-07/LANG-01 reconciliation. Either implementation must check grammar document/configuration epoch before clearing pending state, reporting failure or installing highlights. Global model generations remain reserved for complete model replacement; incrementing one for a single document would strand unrelated resolver jobs. Invalidation must update the live secondary editor and any saved secondary editor state.

Acceptance covers two documents sharing a server, same-revision A-to-B-to-A changes with delayed grammar work, old-session diagnostics/completions, and pending resolver callbacks. The process-descriptor failure is being fixed first because it currently prevents baseline acceptance.
