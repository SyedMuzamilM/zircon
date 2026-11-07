#!/usr/bin/env python3
"""Keep embedded UI examples identical to their compiled Zig source."""
import argparse
import pathlib
import re

DOCUMENT = pathlib.Path("docs/zircon-ui-composition.md")
BLOCK = re.compile(r"(<!-- example: ([^#\n]+)#(\w+) -->\n```zig\n)(.*?)(```)", re.S)


def example(path, function):
    text = pathlib.Path(path).read_text()
    matches = list(re.finditer(rf"(?m)^( +)pub fn {re.escape(function)}\(", text))
    if len(matches) != 1:
        raise ValueError(f"{path}: expected exactly one public {function} function")
    start = matches[0]
    indent = start.group(1)
    end = re.search(rf"(?m)^{re.escape(indent)}\}}$", text[start.end():])
    if end is None:
        raise ValueError(f"{path}: cannot find the function end")
    snippet = text[start.start():start.end() + end.end()]
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in snippet.splitlines()) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = DOCUMENT.read_text()
    updated, count = BLOCK.subn(lambda match: match[1] + example(match[2], match[3]) + match[5], source)
    if count == 0:
        raise SystemExit("No UI examples found")
    if args.write:
        DOCUMENT.write_text(updated)
    elif source != updated:
        raise SystemExit("UI example differs from compiled source; run python3 tools/check_ui_examples.py --write")
    print(f"{count} UI example matches compiled source")


if __name__ == "__main__":
    main()
