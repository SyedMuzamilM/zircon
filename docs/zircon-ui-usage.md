# Build an app with Zircon UI

This guide builds a counter using the current `zircon_ui` API. The [API reference](zircon-ui.md) maps the other APIs to their implementation files and records remaining work.

## Run the existing examples

From the repository root, use the project's Zig `0.17.1` wrapper:

```sh
./tools/zig build counter
```

The command prints `Headless counter: 3 frame-owned nodes`, followed by the count text and button label. It does not open a window.

On macOS, run the native example:

```sh
./tools/zig build counter-native
```

The window shows an Increment button, a count, and an animated bar. Clicking Increment updates both the count and bar.

To compile that native example without opening it:

```sh
./tools/zig build build-native
```

## Connect another application

Create an application directory beside this repository. The paths below assume these sibling directories:

```text
parent/
  zigpui/
  my-zircon-app/
    build.zig
    build.zig.zon
    src/main.zig
```

Use this `build.zig.zon`. Adjust the dependency path if your checkout is elsewhere.

```zig
.{
	.name = .my_zircon_app,
	.version = "0.1.0",
	.fingerprint = 0x2b6f4e940ff4245f,
	.minimum_zig_version = "0.17.1",
	.dependencies = .{
		.zircon_ui = .{ .path = "../zigpui/packages/zircon_ui" },
	},
	.paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

If you change the package name, use the replacement fingerprint suggested by the Zig compiler.

Use this `build.zig` to register the module and executable. The `native` option defaults to `false`; the run command below enables it on macOS.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});
	const native = b.option(bool, "native", "Enable macOS windows and Metal") orelse false;
	const dependency = b.dependency("zircon_ui", .{
		.target = target,
		.optimize = optimize,
		.native = native,
	});
	const exe = b.addExecutable(.{
		.name = "my-zircon-app",
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
			.imports = &.{.{ .name = "zircon_ui", .module = dependency.module("zircon_ui") }},
		}),
	});
	b.installArtifact(exe);
	const run = b.addRunArtifact(exe);
	b.step("run", "Run the counter").dependOn(&run.step);
}
```

## Add the counter

Put this complete program in `src/main.zig`:

```zig
const std = @import("std");
const ui = @import("zircon_ui");

const Counter = struct {
	count: u32 = 0,

	pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
		return b.column(.{
			.padding = ui.Insets.all(24),
			.gap = 12,
			.background = ui.Color.rgb(0x171b24),
		}, &.{
			try b.textFmt("Count: {d}", .{self.count}),
			try b.key(.{ .string = "increment" }, try b.button(.{
				.label = "Increment",
				.on_click = b.onClick(increment),
				.style = .{
					.height = .{ .px = 42 },
					.background = ui.Color.rgb(0x395bd8),
					.radius = 7,
				},
			})),
		});
	}

	fn increment(self: *Counter, _: *ui.Event(ui.Click), cx: *ui.Context(Counter)) void {
		self.count += 1;
		cx.notify();
	}
};

pub fn main(init: std.process.Init) !void {
	var app = try ui.App.init(.{ .allocator = init.gpa });
	defer app.deinit();
	_ = try app.openWindow(Counter, .{
		.title = "My Zircon app",
		.width = 420,
		.height = 240,
	}, .{});
	try app.run();
}
```

From `my-zircon-app`, compile with the repository's compiler wrapper:

```sh
../zigpui/tools/zig build
```

On macOS, open the window:

```sh
../zigpui/tools/zig build run -Dnative=true
```

Click Increment or focus it with Tab and press Enter. The text changes from `Count: 0` to `Count: 1`.

Keep state in the `Counter` entity. Read it in `render`, change it in callbacks, and call `cx.notify()` after changes. Bind handlers with `b.onClick` or `b.onInput` so they refer to the entity identity. Keep elements, builder allocations, and callback contexts within their frame or callback lifetime.

## Compose a larger app

Use these existing examples for each next task:

| Task | API and example |
| --- | --- |
| Create child state | `cx.createChild(T, value)`, as used by the [application bootstrap](../apps/zircon/src/actions.zig) |
| Render another view | `b.view(entity)`, as used by [application views](../apps/zircon/src/view.zig) |
| Read another model during rendering | `b.watch(entity, reader, args)`, covered by [reactivity tests](../packages/zircon_ui/tests/reactive_tests.zig) |
| Edit a single line | Create a `controls.TextInput` entity and compose it with `b.view`, as covered by [control tests](../packages/zircon_ui/tests/control_tests.zig) |
| Copy input text out | `app.read(field, ui.controls.TextInput.copy, .{ allocator, &owned_bytes })`. Free `owned_bytes` with that allocator |
| Pass an item ID to a click callback | `b.onClickWith(callback, id)`, as used by [workspace chrome](../apps/zircon/src/views/chrome.zig) |
| Handle commands | Define an action enum and `ui.Keymap(Action)`, as covered by [control tests](../packages/zircon_ui/tests/control_tests.zig) |
| Draw custom content | Implement `requestLayout`, `prepaint`, and `paint`, as in the [editor canvas](../packages/zircon_editor/src/canvas.zig) |
| Start owned background work | `cx.spawn(Job, job, completion)`, as covered by [owned task tests](../packages/zircon_ui/tests/owned_task_tests.zig) |
| Animate a value | `b.animate(key, target, .{ .spring = .{} })`, as in the [native counter](../examples/counter_native/main.zig) |

For runtime input tests, open an in-memory window, call `app.step(0)`, dispatch input, and inspect the entity through `app.read`. Advance `step` with explicit times for animation tests. Use `testing.Harness` for smaller entity/tree checks. See the [window tests](../packages/zircon_ui/tests/window_tests.zig) for complete examples.

See the [compact composition guide](zircon-ui-composition.md) for the shorter tuple syntax, inline button metadata and compiled source examples.

## Extend the framework

Use the [remaining-work table](zircon-ui.md#remaining-framework-work) to choose a task. For continued work on the current macOS editor, the suggested order is:

1. Complete real OS text-input acceptance and accessibility journeys. Exercise composition, selection replacement, stale edits, keyboard-only use, and screen readers.
2. Extract reusable controls from repeated application patterns. Give each control a state owner, keyboard behavior, focus rules, and accessibility metadata.
3. Add layout or graphics capabilities required by a concrete screen. Keep text wrapping in the editor separate from flex wrapping in the framework.
4. Extend command and native integration APIs where current callers use lower-level window details. Include context keymaps, menus, and save dialogs as their workflows require them.
5. Measure resource use and cancellation behavior under sustained workloads. Follow the [benchmark method](benchmarks/method.md) before making comparative performance claims.
6. Establish package compatibility and distribution rules before treating `0.1.0` as a stable external API. Add native platforms when a target application requires them.

When changing the framework, update the [public exports](../packages/zircon_ui/src/root.zig) and this reference together. Add behavior coverage in the relevant existing suite, then run checks from the repository root:

```sh
./tools/zig build test
./tools/zig build check
```

For macOS window, text, or rendering changes, also run:

```sh
./tools/zig build test-native
```

For changes shared with the editor, use the [fresh native verification procedure](native-verification.md). For portable changes, compile the Linux target as well:

```sh
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
```
