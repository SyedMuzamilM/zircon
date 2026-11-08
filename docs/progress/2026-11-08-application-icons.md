# Application icons

`App.init(.{ .allocator = allocator, .icon = image })` retains an independent `Image` reference. The caller can release its reference after initialization. The application releases its clone during teardown. A `WindowOptions.icon` override borrows an `images.View` only during window creation; adapters must copy its pixels before returning.

The macOS adapter constructs an sRGB-tagged `NSBitmapImageRep` from premultiplied RGBA, stores it in an independent `NSImage`, and keeps it pending until the first successful GPU presentation. Failed entity adoption, discarded windows and failed frames cannot publish a new Dock icon. macOS has one application-wide Dock icon, so the most recently presented window with an explicit icon updates that icon. Linux and Windows window-icon adapters remain open.

The editor supplies a default icon generated from geometry in `apps/zircon/src/app_icon.zig`. The same pixel generator can feed distribution resources without a separate language. Packaged Finder `.icns`, Windows `.ico` and Linux desktop resources are not delivered by this slice. Existing macOS packaging still needs migration to Zig before adding its icon resources.

Native verification checks exact copied premultiplied bytes, the sRGB tag, source-reference release, the application-visible icon and discard-before-presentation. AppKit returns the application icon as a display-space snapshot, so that check verifies opaque red identity. Exact source bytes are verified on the independent bitmap before AppKit's conversion. A review found publication before fallible root creation; publication now follows successful presentation and has a discard test.
