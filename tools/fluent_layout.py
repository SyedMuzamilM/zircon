#!/usr/bin/env python3
"""Keep UI button layout and children in fluent chains, outside option structs.

The scanner skips comments and literals. Named style presets remain supported;
inline styles on newly constructed nodes become typed fluent setters.
"""
import argparse
import pathlib
import re

from migrate_fluent import arguments, style_chain
from migrate_ui_callbacks import code_positions


BUTTON = re.compile(r"\.button\(")


def fields(value):
    value = value.strip()
    if not value.startswith(".{") or not value.endswith("}"):
        return None
    entries, _ = arguments("f(" + value[2:-1] + ")", 2)
    result = []
    for entry in entries:
        match = re.fullmatch(r"\.(\w+)\s*=\s*([\s\S]+)", entry)
        if not match:
            return None
        result.append((match[1], match[2].strip()))
    return result


def migrate(source):
    positions = set(code_positions(source))
    edits = []
    for match in BUTTON.finditer(source):
        if match.start() not in positions:
            continue
        values, end = arguments(source, match.end())
        if len(values) != 1:
            continue
        options = fields(values[0])
        if options is None or not any(name in {"children", "style"} for name, _ in options):
            continue
        metadata = [(name, value) for name, value in options if name not in {"children", "style", "on_click"}]
        handlers = [value for name, value in options if name == "on_click"]
        handler = handlers[0] if handlers else None
        # An optional handler stays in Button's typed options.
        optional = handler is not None and re.search(r"\bnull\b", handler) is not None
        if optional:
            metadata.append(("on_click", handler))
        replacement = ".button(.{\n" + "".join(f".{name} = {value},\n" for name, value in metadata) + "})"
        for name, value in options:
            if name == "style":
                replacement += style_chain(value)
        if handler is not None and not optional:
            replacement += ".on_click(" + handler.removeprefix("try ") + ")"
        for name, value in options:
            if name == "children":
                replacement += ".children(" + value + ")"
        edits.append((match.start(), end, replacement))
    # Apply only innermost edits; the next pass handles enclosing buttons.
    selected = []
    last = len(source) + 1
    for start, end, replacement in reversed(edits):
        if end <= last:
            selected.append((start, end, replacement))
            last = start
    for start, end, replacement in selected:
        source = source[:start] + replacement + source[end:]
    return source


def expand_literals(source):
    """A trailing comma asks zig fmt to keep aggregate layout content expanded."""
    positions = set(code_positions(source))
    edits = []
    for match in re.finditer(r"\.(children|button|style|text_style|padding|listeners)\(", source):
        if match.start() not in positions:
            continue
        values, end = arguments(source, match.end())
        if len(values) != 1:
            continue
        value = values[0]
        aggregate = value[1:] if value.startswith("&.{") else value
        if not aggregate.startswith(".{") or not aggregate.endswith("}"):
            continue
        if len(aggregate) < 70 or aggregate[:-1].rstrip().endswith((",", "{")):
            continue
        at = end - 1
        while source[at] != "}":
            at -= 1
        edits.append(at)
    for at in sorted(set(edits), reverse=True):
        source = source[:at] + "," + source[at:]
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--expand", action="store_true")
    args = parser.parse_args()
    changed = []
    for root in args.paths:
        for path in ([root] if root.is_file() else sorted(root.rglob("*.zig"))):
            if any(part in {".zig-cache", "zig-out", "target"} for part in path.parts):
                continue
            before = path.read_text()
            after = before
            while True:
                next_source = migrate(after)
                if next_source == after:
                    break
                after = next_source
            if args.expand:
                after = expand_literals(after)
            if after == before:
                continue
            changed.append(str(path))
            if not args.check:
                path.write_text(after)
    print(f"{len(changed)} files {'need fluent layout migration' if args.check else 'updated'}")
    if args.check and changed:
        print("\n".join(changed))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
