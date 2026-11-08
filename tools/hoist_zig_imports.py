#!/usr/bin/env python3
"""Move nested literal Zig imports into module declarations.

Uses Zig lexical spans so strings, comments and multiline string literals are
left alone. Existing module aliases are reused; new names avoid local symbols.
"""
import argparse
import pathlib
import re
from migrate_ui_callbacks import code_positions

IMPORT = re.compile(r'@import\("([^"\n]+)"\)')


def import_header(source):
    """Keep actual import declarations together before other declarations."""
    pattern = re.compile(r'(?m)(?:^///[^\n]*\n)*(?:pub )?const \w+ = @import\("([^"\n]+)"\);\n?')
    positions = set(code_positions(source))
    matches = [m for m in pattern.finditer(source) if source.find("@import", m.start(), m.end()) in positions and (m.start() == 0 or source[m.start() - 1] == "\n")]
    if not matches:
        return source
    declarations = []
    for m in matches:
        path = m.group(1)
        rank = 0 if path == "std" else 1 if path == "builtin" else 3 if path.endswith(".zig") else 2
        declarations.append((rank, path, m.group().rstrip("\n") + "\n"))
    for m in reversed(matches):
        source = source[:m.start()] + source[m.end():]
    header = 0
    for line in source.splitlines(keepends=True):
        if line.startswith("//!") or not line.strip():
            header += len(line)
        else:
            break
    return source[:header] + "".join(item[2] for item in sorted(declarations)) + source[header:]


def hoist(source):
    positions = set(code_positions(source))
    depth = {}
    braces = 0
    for i, char in enumerate(source):
        if i in positions:
            depth[i] = braces
            if char == "{":
                braces += 1
            elif char == "}":
                braces -= 1
    imports = [m for m in IMPORT.finditer(source) if m.start() in positions]
    existing = {}
    retained = set()
    for match in imports:
        if depth[match.start()] != 0:
            continue
        before = source[source.rfind("\n", 0, match.start()) + 1:match.start()]
        declaration = re.fullmatch(r'(?:pub )?const (\w+)\s*=\s*', before)
        if declaration and source[match.end():].lstrip().startswith(";"):
            existing.setdefault(match.group(1), declaration.group(1))
            retained.add(match.start())
    identifiers = set(re.findall(r'\b[A-Za-z_]\w*\b', "".join(char if i in positions else " " for i, char in enumerate(source))))
    names = dict(existing)
    declarations = []
    edits = []
    for match in imports:
        if match.start() in retained:
            continue
        path = match.group(1)
        if path not in names:
            name = re.sub(r'\W', '_', pathlib.PurePosixPath(path).stem)
            if not name or name[0].isdigit():
                name = "module_" + name
            if name in identifiers:
                name += "_module"
            while name in identifiers:
                name += "_import"
            identifiers.add(name)
            names[path] = name
            declarations.append(f'const {name} = @import("{path}");\n')
        edits.append((match.start(), match.end(), names[path]))
    if not edits:
        return import_header(source)
    for start, end, replacement in reversed(edits):
        source = source[:start] + replacement + source[end:]
    header = 0
    for line in source.splitlines(keepends=True):
        if line.startswith("//!") or not line.strip():
            header += len(line)
        else:
            break
    return import_header(source[:header] + "".join(declarations) + source[header:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=pathlib.Path)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    changed = []
    for root in options.paths:
        for path in ([root] if root.is_file() else sorted(root.rglob("*.zig"))):
            if any(part in {".zig-cache", "zig-out", "target", "node_modules"} for part in path.parts):
                continue
            before = path.read_text()
            after = hoist(before)
            if after != before:
                changed.append(str(path))
                if not options.check:
                    path.write_text(after)
    print(f"{len(changed)} files {'need import hoisting' if options.check else 'updated'}")
    if options.check and changed:
        print("\n".join(changed))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
