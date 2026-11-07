#!/usr/bin/env python3
"""Run verified native release workloads in disposable projects, preserving raw samples."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.check_output(args, cwd=REPO, text=True).strip()


def source_bytes(size):
    line = ("def transform(value):\n    return value + sum([1, 2, 3, 4, 5, 6, 7, 8])"
            "  # Indented continuation with repeated words, tabs and Unicode 日本語 for the native editor baseline\n").encode()
    return (line * (size // len(line)) + b" " * (size % len(line) - 1) + b"\n")[:size]


def make_project(root, size, services, wrap):
    data = source_bytes(size)
    (root / "main.py").write_bytes(data)
    (root / "settings.json").write_text(json.dumps({"theme": "zircon.dark", "git_inline_blame": False,
                                                 "soft_wrap": "editor_width" if wrap else "none"}))
    if services:
        extension = root / "extensions" / "org.zircon.baseline"
        extension.mkdir(parents=True)
        manifest = {
            "schema_version": 1, "id": "org.zircon.baseline", "name": "Baseline fixtures", "version": "1.0.0",
            "contributes": {
                "languages": [{"id": "python", "name": "Python", "extensions": ["py"],
                               "grammar": {"builtin": True, "name": "python", "wasm": "", "highlights": ""}}],
                "language_servers": [{"id": "baseline.fixture", "languages": ["python"], "command": sys.executable,
                                      "args": [str(REPO / "packages/zircon_language/tests/fixture.py"), "host"]}]
            }
        }
        (extension / "extension.json").write_text(json.dumps(manifest))
        for args in [("init", "-q"), ("config", "user.name", "Baseline"),
                     ("config", "user.email", "baseline@example.invalid"), ("add", "main.py"),
                     ("-c", "commit.gpgsign=false", "commit", "-qm", "baseline")]:
            subprocess.run(["/usr/bin/git", "-C", str(root), *args], check=True, capture_output=True)
    return hashlib.sha256(data).hexdigest()


def tree_rss(pid):
    rows = [row.split() for row in command("ps", "-axo", "pid=,ppid=,rss=").splitlines()]
    processes = {int(p): (int(parent), int(rss)) for p, parent, rss in rows}
    members = {pid}
    while True:
        found = {p for p, (parent, _) in processes.items() if parent in members}
        if found <= members:
            break
        members |= found
    return sum(processes[p][1] for p in members if p in processes)


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--smoke", action="store_true", help="One 32 KiB services case for validating the driver")
    parser.add_argument("--profile", action="store_true", help="One separate instrumented 1 MiB wrap/services run")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    executable = REPO / "zig-out/bin/zircon-editor-bench"
    if not executable.is_file():
        parser.error("Build first: ./tools/zig build build-bench-editor extension-host -Doptimize=ReleaseFast")
    info = {"platform": platform.platform(), "cpu_count": os.cpu_count(), "load_start": os.getloadavg(),
            "model": command("sysctl", "-n", "hw.model"), "memory_bytes": command("sysctl", "-n", "hw.memsize"),
            "os": command("sw_vers"), "zig": command("./tools/zig", "version"),
            "commit": command("git", "rev-parse", "HEAD"), "worktree_status": command("git", "status", "--short"),
            "driver_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "worker_sha256": hashlib.sha256((executable.parent / "zircon-extension-host").read_bytes()).hexdigest(),
            "toolchain_sources_sha256": {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest()
                                          for name in ("tools/zig", "tools/zig_stdlib_overlay.py", "tools/verify_spawn_isolation.zig")},
            "source_sha256": {str(path.relative_to(REPO)): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sorted(set(REPO.glob("packages/zircon_*/src/**/*.zig")) |
                                                 set(REPO.glob("apps/zircon/src/**/*.zig")) |
                                                 {REPO / "build.zig", REPO / "tools/bench_editor.zig",
                                                  REPO / "tools/run_editor_baseline.py", REPO / "packages/zircon_language/tests/fixture.py"})},
            "measurement": "Synthetic Shell input dispatch through App.step/native submission, not scanout",
            "memory": "Sampled sum of driver/descendant RSS at about 100 ms; lower bound on peak; shared pages counted per process",
            "services": "Real local Git, built-in Python Tree-sitter worker and deterministic stdio LSP fixture; no network"}
    (output / "environment.json").write_text(json.dumps(info, indent=2))
    cases = [(1048576, True, True)] if args.profile else [(32768, True, True)] if args.smoke else [(n, w, s) for n in (32768, 1048576) for w in (False, True) for s in (False, True)]
    samples, failures = [], []
    with tempfile.TemporaryDirectory(prefix="zircon-editor-baseline-") as temporary:
        for run in range(1 if args.smoke or args.profile else args.runs):
            # Each round rotates order, so one configuration is not always first/last.
            order = cases[run % len(cases):] + cases[:run % len(cases)]
            for size, wrap, services in order:
                name = f"{size}-{'wrap' if wrap else 'plain'}-{'services' if services else 'core'}-{run + 1}"
                root = Path(temporary) / name
                root.mkdir()
                expected_hash = make_project(root, size, services, wrap)
                result_path = output / (name + ".json")
                log_path = output / (name + ".log")
                started = time.monotonic()
                peak_rss, snapshots = 0, 0
                profiler = None
                with log_path.open("w") as log:
                    process = subprocess.Popen([str(executable), str(root), "wrap" if wrap else "plain",
                                                "services" if services else "core", str(result_path)],
                                               cwd=REPO, stdout=log, stderr=log, start_new_session=True)
                    while process.poll() is None:
                        if args.profile and profiler is None and result_path.with_suffix(".json.ready").exists():
                            profiler = subprocess.Popen(["/usr/bin/sample", str(process.pid), "1", "1", "-file", str(output / "profile.txt")], stdout=log, stderr=log)
                        peak_rss = max(peak_rss, tree_rss(process.pid))
                        snapshots += 1
                        if time.monotonic() - started > 180:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                            break
                        time.sleep(0.1)
                    if profiler is not None:
                        profiler.wait(timeout=10)
                actual_hash = hashlib.sha256((root / "main.py").read_bytes()).hexdigest()
                if process.returncode or not result_path.exists() or actual_hash != expected_hash:
                    failures.append({"case": name, "returncode": process.returncode, "disk_unchanged": actual_hash == expected_hash})
                    print("FAILED " + name, flush=True)
                    continue
                result = json.loads(result_path.read_text())
                if result["errors"] or result["revision"] != 20 or result["frames"] < 20 or len(result["input_to_submit_ms"]) != 20:
                    failures.append({"case": name, "reason": "invalid work counts"})
                    continue
                result.update({"case": name, "run": run + 1, "process_elapsed_s": time.monotonic() - started,
                               "sampled_tree_peak_rss_kib": peak_rss, "rss_samples": snapshots,
                               "source_sha256": expected_hash, "disk_unchanged": True})
                result_path.write_text(json.dumps(result, indent=2))
                samples.append(result)
                print(f"{name}: p95 submit {percentile(result['input_to_submit_ms'], .95):.2f} ms; "
                      f"Git {result['counts']['git_commands']}; LSP {result['counts']['lsp_bytes']} bytes", flush=True)
    summary = []
    for size, wrap, services in cases:
        group = [s for s in samples if s["source_bytes"] == size and s["wrap"] == wrap and s["services"] == services]
        if not group:
            continue
        p95s = [percentile(s["input_to_submit_ms"], .95) for s in group]
        summary.append({"source_bytes": size, "wrap": wrap, "services": services, "runs": len(group),
                        "p95_submit_median_ms": statistics.median(p95s), "p95_submit_range_ms": [min(p95s), max(p95s)],
                        "dispatch_p95_median_ms": statistics.median(percentile(s["dispatch_ms"], .95) for s in group),
                        "step_p95_median_ms": statistics.median(percentile(s["step_ms"], .95) for s in group),
                        "sampled_tree_peak_median_kib": statistics.median(s["sampled_tree_peak_rss_kib"] for s in group),
                        "raw_cases": [s["case"] for s in group]})
    (output / "summary.json").write_text(json.dumps({"profiled": args.profile, "cases": summary, "failures": failures, "load_end": os.getloadavg()}, indent=2))
    print(str(output / "summary.json"))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
