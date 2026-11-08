#!/usr/bin/env python3
"""Migrate eager application composition to fluent chains without editing literals.

Raw custom-element construction remains an explicit ownership boundary. This
command handles composition and decoration; framework implementation and API
contract tests deliberately keep exercising the low-level constructors.
"""
import argparse
import pathlib
import re
from migrate_ui_callbacks import code_positions

METHODS = "row|column|stack|div|textFmt|text|button|view|styled|key|listen|autofocus|requestFocus|modal|dragRegion"
CALL = re.compile(r"\b(b|builder)\.(" + METHODS + r")\(")


def arguments(source, start):
    positions = set(code_positions(source))
    stack = [")"]
    commas = []
    for i in range(start, len(source)):
        if i not in positions:
            continue
        char = source[i]
        if char in "([{":
            stack.append({"(": ")", "[": "]", "{": "}"}[char])
        elif char in ")]}":
            if char != stack.pop():
                raise ValueError("unbalanced Zig expression")
            if not stack:
                slices = []
                previous = start
                for comma in commas:
                    slices.append(source[previous:comma].strip())
                    previous = comma + 1
                if source[previous:i].strip():
                    slices.append(source[previous:i].strip())
                return slices, i + 1
        elif char == "," and len(stack) == 1:
            commas.append(i)
    raise ValueError("unterminated Zig call")


def arg(value):
    # Newlines preserve a trailing line comment at the argument boundary.
    return "(\n" + value + "\n)"


def style_chain(value):
    if not value.startswith(".{") or not value.endswith("}"):
        return ".style" + arg(value)
    fields, _ = arguments("f(" + value[2:-1] + ")", 2)
    out = ""
    methods = {"width": "w", "height": "h", "min_width": "min_w", "max_width": "max_w", "min_height": "min_h", "max_height": "max_h", "padding": "padding", "margin": "margin", "gap": "gap_px", "radius": "rounded_px", "opacity": "opacity", "scroll_y": "scroll_y_px", "text": "text_style", "direction": "direction", "align_items": "items", "justify_content": "justify", "background": "background", "hover_background": "hover_background", "flex_grow": "grow_by", "flex_shrink": "shrink_by"}
    short = {("flex_grow", "1"): "grow", ("flex_shrink", "0"): "shrink_0", ("align_items", ".center"): "items_center", ("justify_content", ".center"): "justify_center", ("justify_content", ".space_between"): "justify_between", ("overflow", ".hidden"): "overflow_hidden", ("direction", ".row"): "flex", ("direction", ".column"): "flex_col", ("direction", ".stack"): "stack"}
    for field in fields:
        match = re.fullmatch(r"\.(\w+)\s*=\s*([\s\S]+)", field)
        if match is None:
            return ".style" + arg(value)
        name, expression = match.group(1), match.group(2).strip()
        if (name, expression) in short:
            out += "." + short[name, expression] + "()"
        elif name in methods:
            out += "." + methods[name] + arg(expression)
        else:
            # Typed refinements preserve the untouched style fields.
            return ".style" + arg(value)
    return out


def migrate(source):
    while True:
        positions = set(code_positions(source))
        matches = [m for m in CALL.finditer(source) if m.start() in positions]
        if not matches:
            return source
        match = matches[-1]
        values, end = arguments(source, match.end())
        owner, method = match.group(1, 2)
        f = owner + ".fluent()"
        if method in ("row", "column", "stack", "div"):
            assert len(values) == 2
            tail = style_chain(values[0])
            # Eager row/column/stack override Style.direction.
            direction = {"row": ".flex()", "column": ".flex_col()", "stack": ".stack()", "div": ""}[method]
            replacement = f + ".div()" + tail + direction + ".children" + arg(values[1]) + ".build()"
        elif method in ("text", "textFmt", "button", "view"):
            replacement = f + "." + method + "(\n" + ",\n".join(values) + "\n).build()"
        elif method == "key":
            replacement = f + ".adopt" + arg(values[1]) + ".id" + arg(values[0]) + ".build()"
        elif method in ("styled", "listen", "requestFocus"):
            modifier = {"styled": "style", "listen": "listeners", "requestFocus": "request_focus"}[method]
            replacement = f + ".adopt" + arg(values[0]) + "." + modifier + arg(values[1]) + ".build()"
        else:
            modifier = {"autofocus": "autofocus", "modal": "modal", "dragRegion": "drag_region"}[method]
            replacement = f + ".adopt" + arg(values[0]) + "." + modifier + "().build()"
        source = source[:match.start()] + replacement + source[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    changed = []
    for root in options.paths:
        for path in ([root] if root.is_file() else sorted(root.rglob("*.zig"))):
            source = path.read_text()
            result = migrate(source)
            if result != source:
                changed.append(str(path))
                if not options.check:
                    path.write_text(result)
    print(f"{len(changed)} files {'need migration' if options.check else 'migrated'}")
    if options.check and changed:
        print("\n".join(changed))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
