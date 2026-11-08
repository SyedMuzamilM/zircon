# Zed package boundaries and Zircon placement

Inspected the local checkout `/tmp/zigpui-zed-current-20261106` through `git show` at immutable Zed commit `b5cd310b3b54dfc659fcc06453e6358843dfe216`. Its working-tree HEAD is a different revision, so paths alone do not identify the inspected version. This note describes source ownership, not native runtime acceptance.

## What owns what in Zed

| Package | Source-backed responsibility | Dependency direction |
| --- | --- | --- |
| `extension` | Manifest, resources, capabilities, extension traits, host proxy and contribution events. It defines worktree/project delegates and language-server operations. | Depends on GPUI for `App`, `EntityId` and `Task`, as well as language, filesystem and protocol packages. It is separate from presentation, but not completely UI-framework-independent. |
| `extension_host` | Installed extension runtime/store behavior consumed by the UI. This is distinct from extension contribution contracts. | `extensions_ui` consumes its `ExtensionStore`, status and operation types. |
| `extensions_ui` | Extension screen, suggestions, version selector and extension-card presentation. | Consumes `extension`, `extension_host`, workspace/editor integration and shared `ui` components. |
| `ui` | Reusable Zed application components, styles, animation helpers and component preludes. It is above the GPUI framework. | Depends on GPUI, theme, icons and menu support. Feature screens consume it. |
| `gpui` | Framework elements, style refinements, entities, actions, windows and platform contracts. | Platform implementations fulfill its interfaces. `Styled` methods refine typed style values; container child composition belongs to the element system. |
| `gpui_macos` | macOS lifecycle, windows, input, keyboard/pasteboard, display handling, native menus and system integration. | Uses shared Apple services and the Metal renderer from `gpui_apple`. |
| `gpui_apple` | Shared Metal renderer/atlas, Apple text system, dispatcher, Keychain and process/thermal services. | Leaves platform lifecycle, windowing and input to the OS adapter. |
| `gpui_platform` | Platform selection and convenience application constructors. | Selects macOS, Windows, Linux and other implementations behind one entry point. |

Primary sources at the inspected revision:

- [Extension manifest and dependencies](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/extension/Cargo.toml), [extension contracts](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/extension/src/extension.rs).
- [Extensions UI dependencies](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/extensions_ui/Cargo.toml), [extension card](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/extensions_ui/src/components/extension_card.rs).
- [Shared UI entry point](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/ui/src/ui.rs), [UI dependencies](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/ui/Cargo.toml), [GPUI styling](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/styled.rs).
- [macOS adapter](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui_macos/src/gpui_macos.rs), [macOS platform/menu integration](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui_macos/src/platform.rs), [shared Apple responsibilities](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui_apple/src/gpui_apple.rs), [platform selection](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui_platform/src/gpui_platform.rs).
- [Editor application menu declarations](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/zed/src/zed/app_menus.rs), [GPUI menu data types](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/platform/app_menu.rs).

## What this means for Zircon

Keep `packages/zircon_extensions` as the contribution/data package. Its build currently imports no `zircon_ui`; that independence is useful and stronger than copying every Zed dependency. Its registry, manifest and snapshot types must not gain widgets or native handles.

Keep extension screen composition in `apps/zircon/src/views/extensions.zig` and host/application coordination in `apps/zircon/src/services/extensions.zig` and `extension_host.zig`. Moving a file to a new package does not itself establish a cleaner dependency. Extract a separately consumable feature UI package when there is an actual reuse or dependency boundary to enforce.

Put generic menus, lists and controls in `zircon_ui`, with typed input/actions and no `Shell` or editor command imports. Keep editor palette choices and product-specific composites in `apps/zircon/src/views/components.zig`. The framework's `Style` and new fluent API must not acquire Zed-specific theme or extension types.

Put native menu creation, application icon publication, window/input integration and GPU resource handling behind their platform interfaces. The current icon adapter lives under `platform/macos`; the generic application owns the retained image, and the native adapter owns its copied image. Failed staging must not replace the installed menu/action generation or icon. Existing Metal rendering remains in `graphics/backends/metal.zig` and text shaping in `text/shaping.zig`.

The new Linux/Windows renderer needs equivalent separation between native window/services, shaped text and GPU resources. A shared Vulkan implementation may serve multiple adapters, but platform input, IME, dialogs, menus and accessibility still have OS-specific behavior. Do not move those policies into generic elements or the editor Shell.

## Acceptance implications

Menus must be complete action integrations: enabled/checked state, shortcuts, native responder behavior, active-window routing, stale-target refusal and teardown. A visually drawn menu row does not establish that contract. Library context/popover menus are a separate reusable control above the same typed commands.

Fluent syntax must be checked against actual Zed editor-style call sites, including component composition and dynamic children. A style-only chain may be useful, but cannot be described as the full GPUI child/event API. Keep Zircon's eager copied text, generational ownership, pointer-free callback payloads and failed-frame rollback throughout.

Icons need both runtime ownership and distribution resources. A Dock icon alone does not provide Finder, Windows executable/taskbar or Linux desktop-file identity. Current runtime icon work is documented separately in [application icons](../progress/2026-11-08-application-icons.md).
