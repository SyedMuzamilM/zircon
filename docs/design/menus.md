# Application and library menus

The reference is Zed's actual editor menu declarations and GPUI action/platform integration at `b5cd310b3b54dfc659fcc06453e6358843dfe216`. Generic menu behavior belongs to `zircon_ui`; product labels and command semantics belong to the editor. Extension contribution data must not acquire a UI dependency. See the [source boundary map](../research/zed-package-boundaries-2026-11-08.md).

## Selected direction

Two independent inherited-model sketches compared frame-declared menu callbacks with application-owned menu schemas and action routes. Model diversity is reduced; no different-family judge is configured. The implementation has not started.

Use application-owned schemas and generational action routes as the base. Native menu structure should survive ordinary view rebuilds, and process-wide application actions must not require a live editor frame. Reject pinning an editor's committed frame for the duration of native menu tracking. That would complicate close/focus handling and defer visible updates while a menu is open.

Take the frame candidate's explicit native preparation/commit contract, common menu model for native and library presentation, and committed focus context. Do not retain a second frame callback registry. Menu commands must reach the same typed action executor as keyboard commands, with captured window/owner generations and pointer-free payloads. Cached enabled/checked state is presentation; activation revalidates current domain state.

## Ownership and input contracts

- The application owns copied menu strings, schemas, binding tables and action registrations. Native objects own independent representations. A schema/native preparation failure preserves the installed generation.
- A queued menu request captures its intended window/route generation. A later focus switch cannot redirect it into a different document. Dead owners, stale generations and disabled actions refuse activation.
- The active framework focus context comes from a successful frame. Popup dismissal restores focus only if the saved logical target still exists. A focused search field cannot fall through to undoing the background editor.
- Native callbacks enqueue value requests and return. Entity queries or action execution happen at a safe application boundary, outside mutable borrows. Validators may use a cached snapshot while an update is active.
- Cut, Copy, Paste and Select All preserve native responder behavior in OS dialogs. Zircon's custom views route semantic editing actions to their focused provider. Do not implement menus by manufacturing hardcoded key chords.
- Effective structured shortcuts come from the same default/override/unbind resolution as keyboard dispatch. Display strings are derived from those chords. Control and Super remain distinct.
- macOS has one process menu that follows the active window. Windows menus attach to native windows. Linux needs a rendered menu bar unless an actual desktop/global-menu integration is implemented and verified.

## Public shape to implement

The typed interface needs an owned menu schema, a pointer-free generational menu handle, a typed command route bound to an existing entity, and a captured action context. Internal native indices and OS objects remain private. Menu items represent actions, separators, submenus and explicit OS roles. An action has current enabled/checked state and an effective shortcut.

The first unit is the owned schema and real-`App` queue/dispatch behavior. Verify failed replacement, dead owner/window, active-window changes after queueing, state revalidation and override/unbind consistency. Then implement the native macOS File/Edit/View/Window menus and focused semantic Edit actions together. The library popup uses the same schema/actions with its own selection, submenu, scrolling, dismissal and focus-restoration state.

Native acceptance must cover two windows, a focused editor, text field, terminal and native dialog, menu rebuild while tracking, source destruction and queued callbacks. Library acceptance includes keyboard and pointer interaction, disabled/separator skipping, checked state, submenu navigation, viewport placement and accessibility semantics. A menu-description array or drawn row alone does not satisfy the feature.
