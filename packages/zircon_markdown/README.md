# Zircon Markdown

UI-independent Markdown parsing with owned source ranges. `parse(allocator, utf8_bytes)!Document` copies input into a document arena. `Document.deinit()` releases blocks, inline spans, tables and strings together. Ranges are byte offsets into the original UTF-8 source, so a host can reveal real editable text.

The parser covers headings, paragraphs, fenced code, list items, quotes, rules, tables and inline text/emphasis/strong/code/links/images. Input is capped at 16 MiB. This is a Markdown subset, without CommonMark conformance or executable HTML output.

The native host is `apps/zircon/src/views/markdown.zig`. It retains a parsed generation, lays out framework text, colors code fences, decodes relative local images and maps clicks to source. Frames retain the generation until retirement, so edits cannot invalidate submitted rendering. Source edits prepare a replacement before releasing the old preview. Remote images report unavailable; links are explicit host actions.

Run `./tools/zig build test-markdown` for parser checks and `./tools/zig build test-editor-native` for source/preview and renderer journeys.
