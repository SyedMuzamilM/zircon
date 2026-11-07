# Git UI correctness smoke

One fresh release process per configuration, eight configurations and160 validated input operations. All attempts passed. The 32 KiB/1 MiB × wrap on/off × core/services cases retain raw samples, process logs and source/binary hashes. The updated Git status path includes line-count enrichment. This is a correctness smoke after the UI/status changes, not the repeated five-run baseline and not proof of a speedup, a regression threshold or parity with Zed. The earlier repeated40/40 matrix remains the latency baseline with its stated limits.

The runner validates actual native frame submissions, restored buffer bytes, unchanged fixture disk files and current service revisions. Native submission excludes physical input/GPU completion/display scanout. Existing desktop load was uncontrolled. Services use local Git, a real built-in grammar and deterministic LSP fixture, not general language-server workloads. See `../editor-method.md`.
