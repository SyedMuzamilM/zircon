#!/usr/bin/env python3
"""Migrate the value-first UI callbacks from a fixed source revision."""
import argparse
import pathlib
import re
import subprocess


def code_positions(source):
    """Yield positions outside Zig strings and comments."""
    index = 0
    while index < len(source):
        if source.startswith("//", index) or source.startswith("\\\\", index):
            end = source.find("\n", index)
            index = len(source) if end == -1 else end + 1
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        elif source[index] in "\"'":
            quote = source[index]
            index += 1
            while index < len(source):
                char = source[index]
                index += 1
                if char == "\\":
                    index += 1
                elif char == quote:
                    break
        else:
            yield index
            index += 1


def old_calls(source, locations=False):
    positions = list(code_positions(source))
    position_set = set(positions)
    for match in re.finditer(r"\.(?:onClickWith|onInputWith)\(", source):
        if match.start() not in position_set:
            continue
        start = match.end()
        stack = [")"]
        commas = []
        for index in positions:
            if index < start:
                continue
            char = source[index]
            if char in "([{":
                stack.append({"(": ")", "[": "]", "{": "}"}[char])
            elif char in ")]}":
                if not stack or char != stack.pop():
                    raise ValueError("unbalanced callback arguments")
                if not stack:
                    trailing = ""
                    callback_end = index
                    if len(commas) == 2 and not any(source[p].strip() for p in positions if commas[1] < p < index):
                        callback_end = commas.pop()
                        trailing = "," + source[callback_end + 1:index]
                    if len(commas) != 1:
                        raise ValueError("callback needs exactly two arguments")
                    comma = commas[0]
                    replacement = match.group() + source[comma + 1:callback_end] + ", " + source[start:comma] + trailing + ")"
                    old = source[match.start():index + 1]
                    yield (match.start(), index + 1, old, replacement) if locations else (old, replacement)
                    break
            elif char == "," and len(stack) == 1:
                commas.append(index)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="revision", required=True, help="revision with the old callback API")
    parser.add_argument("--check", action="store_true", help="report remaining migrations without editing")
    args = parser.parse_args()
    names = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", args.revision], text=True).splitlines()
    changed = 0
    for name in names:
        path = pathlib.Path(name)
        if path.suffix != ".zig" or not path.exists():
            continue
        original = subprocess.check_output(["git", "show", f"{args.revision}:{name}"], text=True)
        current = path.read_text()
        updated = current
        migrations = dict(old_calls(original))
        replacements = [(start, end, migrations[old]) for start, end, old, _ in old_calls(current, locations=True) if old in migrations]
        for start, end, replacement in reversed(replacements):
            updated = updated[:start] + replacement + updated[end:]
        if updated != current:
            changed += 1
            print(name)
            if not args.check:
                path.write_text(updated)
    print(f"{changed} files {'need migration' if args.check else 'migrated'}")
    if args.check and changed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
