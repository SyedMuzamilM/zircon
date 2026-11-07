#!/usr/bin/env python3
"""Kill and restart the actual native recovery driver in disposable projects."""
import hashlib
import json
import pathlib
import signal
import subprocess
import sys
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def scenario(driver, parent, name, external=False, discard=False):
    root = parent / name
    root.mkdir()
    home = root / "recovery"
    source = root / "file.txt"
    source.write_bytes(b"disk\n")
    expected = digest(source)
    command = [str(driver), "discard" if discard else "seed", str(root), str(home)]
    with (root / "seed.log").open("w") as log:
        child = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 25
            while not (root / "checkpoint.ready").exists():
                if child.poll() is not None:
                    raise RuntimeError(f"{name}: seed exited {child.returncode}; see {log.name}")
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"{name}: checkpoint never acknowledged; see {log.name}")
                time.sleep(0.01)
            child.send_signal(signal.SIGKILL)
            child.wait(timeout=10)
            if child.returncode != -signal.SIGKILL:
                raise RuntimeError(f"{name}: expected SIGKILL, got {child.returncode}")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
    if digest(source) != expected:
        raise RuntimeError(f"{name}: checkpoint changed original disk bytes")
    if external:
        source.write_bytes(b"external change\n")
        expected = digest(source)
    mode = "verify-discard" if discard else "verify-conflict" if external else "verify"
    result = subprocess.run([str(driver), mode, str(root), str(home)], capture_output=True, text=True, timeout=25)
    (root / "restart.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{name}: restart failed {result.returncode}; see {root / 'restart.log'}")
    if digest(source) != expected:
        raise RuntimeError(f"{name}: restart changed original disk bytes")
    return {"scenario": name, "result": "passed", "terminated_by": "SIGKILL", "original_file_sha256": expected}


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_recovery.py /path/to/zircon-recovery-journey")
    driver = pathlib.Path(sys.argv[1]).resolve()
    # Keep evidence on failures as well as successes.
    parent = pathlib.Path(tempfile.mkdtemp(prefix="zircon-recovery-"))
    print(f"Recovery evidence: {parent}", flush=True)
    results = [
        scenario(driver, parent, "saved-untitled-panes"),
        scenario(driver, parent, "external-rewrite", external=True),
        scenario(driver, parent, "discarded-document", discard=True),
    ]
    for mode, verify in [("close-clean", "verify-clean"), ("close-discard", "verify-empty")]:
        root = parent / mode
        root.mkdir()
        source = root / "file.txt"
        source.write_bytes(b"disk\n")
        expected = digest(source)
        home = root / "recovery"
        for operation in [mode, verify]:
            result = subprocess.run([str(driver), operation, str(root), str(home)], capture_output=True, text=True, timeout=25)
            (root / f"{operation}.log").write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(f"{operation}: failed {result.returncode}; see {root}")
        if digest(source) != expected:
            raise RuntimeError(f"{mode}: changed original disk bytes")
        results.append({"scenario": mode, "result": "passed", "original_file_sha256": expected})
    (parent / "verification.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
