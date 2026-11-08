# Zircon widgets

Shared application colors and visual controls above `zircon_ui`, similar to the role of Zed's `ui` crate above GPUI. This package owns semantic palettes, spacing, text/icons, button styles, input appearances and floating panels. It has no dependency on the editor, workspace or application commands.

The application supplies action listeners and icon-theme resolution. The Git UI package consumes the same controls directly. Native consumers set `.native = true`, matching their UI framework dependency.

Run `./tools/zig build test-widgets` from the repository root, or `../../tools/zig build test` here.
