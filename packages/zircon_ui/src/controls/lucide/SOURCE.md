# Lucide control icons

SVG subset from https://github.com/lucide-icons/lucide at commit
`b826f0c527e1498f5e46f41ca0277ccab144bf31`. See LICENSE for the ISC and MIT
notices, including the Feather-derived artwork attribution.

`python3 tools/generate_icons.py` regenerates `icon_paths.zig` offline from these
SVGs. `--fetch` retrieves this exact pinned revision. Curves flatten with a
0.08-unit tolerance on the original 24-unit grid. Zircon renders round-capped
segments through Metal at the window's actual display scale. No icon font,
external renderer, or runtime SVG parser is required.
