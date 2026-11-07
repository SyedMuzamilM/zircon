# Current native UI captures

Generated with the actual native Shell using the disposable EditorReview source/Git fixture:

```sh
./tools/zig build capture-ui-review -Dreview-project=/tmp/zircon-ui-review/EditorReview -Dreview-output=/tmp/zircon-editor-program-captures --summary all
```

The capture target completed successfully. It exercises dark/light editor, commands, selection, workspace/split menus, settings and font picker, Git, Markdown, project search and narrow layouts. Most editor frames are1240×820 logical pixels; settings and narrow scenarios have their own dimensions. The source snapshot is `dc56004` plus unchanged baseline instrumentation/tooling. The private Darwin stdlib fix is active.

These are native client-area renders; AppKit traffic lights are outside the exported frame. Their actual native objects are checked separately by the window tests. Screenshots establish layout and paint at a captured state, not latency, complete keyboard accessibility, IME or full parity. Services and fallback highlighting differ from the clean historical Zed screenshots. Do not treat a raw pixel difference as a defect without checking those conditions.

The installed Zed binary is unchanged from the clean reference captures in `../../zed-ui/evidence/`. The new Zed capture in the parent directory remains trust-obscured and is explicitly rejected for clean-editor comparison. No personal source files or preferences were captured.
