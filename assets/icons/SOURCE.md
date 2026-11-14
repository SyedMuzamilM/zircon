# SVG icon sources

UI icons use the unchanged SVGs from [Zed assets/icons](https://github.com/zed-industries/zed/tree/4a6121bb0f10c6e8037b741b7dc0a4cd639ae289/assets/icons), pinned to that revision. square.svg and square-check.svg come from [Lucide](https://github.com/lucide-icons/lucide/tree/b826f0c527e1498f5e46f41ca0277ccab144bf31/icons), pinned to that revision. LICENSES and LICENSE retain the complete upstream ISC notices.

Run `python3 tools/generate_icons.py` to regenerate the native geometry offline. The generated strokes retain SVG widths; fills retain their shape, holes and opacity. Icons receive semantic theme colors at drawing time. All product icon names map to this directory in the generator.

terminal.svg, language_server.svg, and warning.svg are original Zircon icons using the same 24-pixel stroke grid.

expand_up.svg, expand_down.svg, and expand_vertical.svg use unchanged [Zed context expansion icons](https://github.com/zed-industries/zed/tree/b5cd310b3b54dfc659fcc06453e6358843dfe216/assets/icons), pinned to that revision under the same ISC license.
