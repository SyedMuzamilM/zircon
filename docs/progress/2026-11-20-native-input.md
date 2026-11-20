# macOS input and accessibility check

Checked a visible Zircon window on Mac15,12 running macOS 27.0 (26A428). A temporary probe used the editor's AppKit first responder, a disposable project and an isolated settings file. The probe restored the previous input source after each run.

## Japanese IME

The macOS Japanese Romaji input source received the `A` key code through a CoreGraphics event. In two attempts the editor reported marked text containing `あ`. Return ended the marked range and left exactly one `あ` in the document. An earlier attempt inserted Latin `a` followed by a newline. This verifies a composition and commit path and leaves repeatability, cancellation and the other TEXT-02 cases open.

## Keyboard focus

The fresh native suite passed. The foreground AppKit event queue delivered keys to the current key window after a focus change. The editor journey verified native typing in project search, the command palette, open path, find and replace. The local check, fresh native suite and real-language target finished with 422 tests passed and seven skipped, including the optional ZLS journey. The Apple clangd completion journey passed.

## Grapheme navigation and deletion

The probe sent Left, Right and Backspace through the AppKit window. Left from the end of a single cluster should reach byte zero, and Backspace from the end should remove the entire cluster. All four clusters split.

| Input | Byte offset after Left | Text left after Backspace |
| --- | ---: | --- |
| `e` with combining acute accent | 1 | `e` |
| India flag | 4 | First regional indicator `🇮` |
| Thumbs up with skin-tone modifier | 4 | `👍` |
| Woman technologist | 7 | `👩‍` |

The movement and deletion handlers use code-point boundaries. TEXT-03 tracks the grapheme behavior.

## Accessibility

With the native completion list visibly open, the macOS accessibility API exposed the Close, Minimize and Full Screen controls. The editor and the two visible completion choices were absent from the accessible window tree. The VoiceOver shortcut and a direct launch of VoiceOver both left it disabled on this host, so spoken navigation remains unverified. The missing elements block accessible navigation of both targets. [Framework accessibility milestone](../zircon-ui-roadmap.md)
