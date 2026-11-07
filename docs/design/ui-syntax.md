# Smaller UI composition

The goal is less repeated syntax at normal call sites while preserving immediate ownership, typed callbacks and failed-frame rollback. Two independent same-model design attempts considered flat constructor options and deferred descriptions. The synthesis keeps immediate builders and adopts eager tuple composition. No different-family judge was configured.

## Caller contract

```zig
return b.column(.{ .padding = .all(24), .gap = 12 }, .{
    b.textFmt("Count: {d}", .{self.count}),
    b.button(.{
        .key = .named("increment"),
        .label = "Increment",
        .on_click = b.onClick(increment),
        .style = .{ .height = .pixels(42), .background = .rgb(0x395bd8) },
    }),
});
```

Constructors still return `!Element`. Containers accept tuples containing `Element` and `!Element`, and existing arrays/slices. Modifiers accept either an element or its fallible result. A child or handler error propagates through the parent to render; nothing substitutes a placeholder. All children resolve and validate before any parent link changes.

Buttons accept their stable key, input listeners and focus options directly. `onClickWith(callback, payload)` and `onInputWith(callback, payload)` infer the payload from the typed callback. Pointer-free payload checks remain in the adapter. `Style` stays a named, validated type; it is not copied into a second generated options schema. Contextual `.all`, `.rgb` and `.pixels` reduce qualification without adding a separate language.

## Ownership and errors

Tuple expressions execute eagerly. Text constructors copy strings immediately, handlers copy payloads into the frame, and successful custom construction immediately registers cleanup. A parent error may occur after siblings already constructed their nodes. Discarding that staging frame releases those resources. Custom construction retains its existing contract: ownership transfers only on success; the caller cleans up its value on failure.

Keys, styling and listener modifiers remain useful for decorating reusable components that already return an element. They accept fallible elements directly, so callers do not need nested `try` expressions. Dynamic lists retain ordinary explicit allocation/error handling.

## Rejected alternatives

Deferred descriptors would create a second lifetime for text and owning custom elements. A helper could return a descriptor pointing at its local text, or an earlier child could fail before a later owning descriptor was visited. Fixing those cases would introduce another ownership protocol. Flat generated style/metadata options would also duplicate the styling contract and change every text constructor signature. Neither earns its complexity for the initial syntax improvement.

Zig 0.17.1 requires the optional to wrap the fallible handler, `?anyerror!Handler`. A generic anonymous button-options argument loses contextual style inference. The implementation therefore preserves typed options and handles child tuples at container boundaries.

## Verification and adoption

Exercise mixed tuple/slice order, callbacks and focus, failed middle children, invalid styles, duplicate parenting, stale/foreign elements, and owning custom cleanup after sibling failure. Compile-fail fixtures reject non-element children and borrowed handler payloads. Compile the documented examples and migrate the native/headless counters plus real application components. Existing frame, input, native and recovery journeys remain acceptance gates.

The implementation preserves the selected eager contract. Six composition behaviors cover mixed child shapes, payload/focus behavior, failure before parenting, exactly-once cleanup of later owning siblings, allocation failures and heap-backed large pointer arrays. The pointer-array path explicitly coerces to a slice before normalization; temporary handle buffers use the frame arena rather than large stack arrays.

The application migrated to callback-first payload inference. The two counters, common menu rows and project rows use the compact construction forms. A fixed-revision migration tool edits only lexical calls and preserves strings, nested comments and line-comment terminators. CLI tests prove repeatability in a disposable repository. [The public guide](../zircon-ui-composition.md) embeds compiled example source and the build checks synchronization.

Entity results and callback payloads now share one recursive copied-value guard. Compile-fail fixtures reject pointers hidden in error-union fields as well as direct pointers. The nested entity-result fixture compiled before the fix, reproducing an escape from the documented contract; it now fails with the expected ownership diagnostic.

Final validation passed all 42 check steps, 112 framework checks, all 117 fresh native checks, all five recovery subprocess cases and all 14 Linux portable compilation steps. Some unaffected suites were cached. Independent source review accepted the core ownership/callback design after fixes for stack allocation and array-to-slice recursion; lexical migration findings have dedicated tests. [Preserved logs](../reviews/editor-program-2026-11-07/ui-composition-evidence/README.md) record the verification scope.


## Requested fluent styling

The next API design must provide GPUI-style fluent composition and Tailwind-like typed style methods. The current eager tuple syntax remains implemented. A fluent design is not implemented yet.

Acceptance requires real editor examples for containers, text, buttons, listeners, menus and icons. Compare call-site size and readability while preserving const render, frame lifetimes, fallible composition, pointer-free callback payloads and failed-frame rollback. Prefer typed methods over runtime class-string parsing. Document the spacing scale, pixel units, conditional styles, theme tokens and precedence. Avoid keeping two unrelated style systems.
