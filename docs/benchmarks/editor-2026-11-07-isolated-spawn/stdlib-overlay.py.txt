#!/usr/bin/env python3
"""Prepare a private Zig 0.17.1 stdlib with Darwin child-handle isolation.

Darwin has no atomic pipe2(O_CLOEXEC). A concurrent spawn can inherit a pipe
between pipe() and fcntl(), keeping another service's stdin open indefinitely.
CLOEXEC_DEFAULT makes inheritance explicit in the existing spawn file actions.
The installed compiler and its original standard library are never modified.
"""
import fcntl
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def source_digest(library, replacement=None):
    """Fingerprint library contents, excluding only our generated manifest."""
    digest = hashlib.sha256()
    for path in sorted(library.rglob("*")):
        if not path.is_file() or path.name == "zircon-overlay.json":
            continue
        relative = path.relative_to(library).as_posix()
        contents = replacement[1] if replacement and relative == replacement[0] else path.read_bytes()
        digest.update(relative.encode() + b"\0")
        digest.update(hashlib.sha256(contents).digest())
    return digest.hexdigest()


def prepare(compiler):
    """Return a verified library directory, publishing a complete cache atomically."""
    environment = subprocess.check_output([str(compiler), "env"], text=True)
    match = re.search(r'^\s*\.lib_dir = ("(?:[^"\\]|\\.)*"),$', environment, re.MULTILINE)
    if match is None:
        raise RuntimeError("Cannot locate the pinned compiler's standard library")
    library = Path(json.loads(match[1])).resolve()
    relative = Path("std/Io/Threaded.zig")
    original = (library / relative).read_bytes()
    anchor = b"        .START_SUSPENDED = start_suspended,\n"
    patched_anchor = anchor + b"        .CLOEXEC_DEFAULT = true,\n"
    if patched_anchor in original:
        return library
    if original.count(anchor) != 1 or b"fn spawnDarwin(" not in original:
        raise RuntimeError("Pinned Darwin spawn implementation changed; review the isolation patch")
    patched = original.replace(anchor, patched_anchor, 1)
    expected_digest = source_digest(library, (relative.as_posix(), patched))
    key = hashlib.sha256(str(library).encode() + expected_digest.encode()).hexdigest()[:24]
    cache = Path(__file__).resolve().parents[1] / ".tools/zig-stdlib-overlay"
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / key
    with (cache / "prepare.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if destination.exists():
            if source_digest(destination) != expected_digest:
                raise RuntimeError("Cached Darwin isolation overlay changed; refusing to use it")
            return destination
        with tempfile.TemporaryDirectory(prefix="preparing-", dir=cache) as temporary:
            staging = Path(temporary) / "lib"
            shutil.copytree(library, staging, symlinks=True)
            (staging / relative).write_bytes(patched)
            if source_digest(staging) != expected_digest:
                raise RuntimeError("Standard library changed during isolation preparation")
            (staging / "zircon-overlay.json").write_text(json.dumps({
                "patch": "darwin-spawn-cloexec-default-v1",
                "source_library": str(library),
                "source_sha256": hashlib.sha256(original).hexdigest(),
                "patched_sha256": hashlib.sha256(patched).hexdigest(),
                "library_sha256": expected_digest,
            }, indent=2))
            staging.rename(destination)
    return destination


if __name__ == "__main__":
    try:
        print(prepare(Path(sys.argv[1])))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Cannot prepare Darwin process isolation: {error}")
