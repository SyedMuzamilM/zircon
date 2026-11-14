#!/usr/bin/env python3
"""Measure correct native Git actions in fresh release processes and disposable files."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--driver', type=Path, default=REPO / 'zig-out/bin/zircon-git-bench')
    parser.add_argument('--baseline-driver', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=5)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    args.output.mkdir(parents=True, exist_ok=False)
    driver = args.driver.resolve()
    environment = {'platform': platform.platform(), 'driver_sha256': hashlib.sha256(driver.read_bytes()).hexdigest(), 'runs': args.runs, 'files': 8, 'lines_per_file': 4000, 'hunks': 312, 'source_hashes': {str(p): hashlib.sha256((REPO / p).read_bytes()).hexdigest() for p in ['tools/bench_git_interactions.zig', 'apps/zircon/src/actions.zig', 'apps/zircon/src/services/git.zig', 'packages/zircon_git_ui/src/layout.zig', 'packages/zircon_editor/src/wrap.zig']}}
    drivers = [('current', driver)]
    if args.baseline_driver:
        baseline = args.baseline_driver.resolve()
        environment['baseline_driver_sha256'] = hashlib.sha256(baseline.read_bytes()).hexdigest()
        drivers.insert(0, ('baseline', baseline))
    environment['uptime'] = subprocess.check_output(['uptime'], text=True).strip()
    (args.output / 'environment.json').write_text(json.dumps(environment, indent=2))
    summary = []
    with tempfile.TemporaryDirectory(prefix='zircon-git-actions-') as directory:
        root = Path(directory)
        old = ''.join(f'const value_{i} = false;\n' for i in range(1, 4001))
        files = [root / 'main.zig'] + [root / f'z{i}.zig' for i in range(7)]
        for file in files:
            file.write_text(old)
        for command in [('init', '-qb', 'main'), ('config', 'user.name', 'Git interaction fixture'), ('config', 'user.email', 'fixture@example.invalid'), ('add', '.'), ('-c', 'commit.gpgsign=false', 'commit', '-qm', 'Initial')]:
            subprocess.run(['git', '-C', directory, *command], check=True, capture_output=True)
        new = ''.join(line.replace('false', 'true') if i >= 101 and (i - 101) % 100 == 0 else line for i, line in enumerate(old.splitlines(keepends=True), 1))
        for file in files:
            file.write_text(new)
        expected = hashlib.sha256(new.encode()).hexdigest()
        for run in range(args.runs):
            order = drivers if run % 2 == 0 else list(reversed(drivers))
            for label, executable in order:
                output = args.output.resolve() / f'{label}-run-{run + 1}.json'
                subprocess.run([str(executable), directory, str(output)], check=True, timeout=180)
                result = json.loads(output.read_text())
                if result['errors'] != 0 or result['expansions'] != 4 or result['edits'] != 24 or result['tabs'] != 1:
                    raise RuntimeError('Incorrect interaction work')
                for file in files:
                    if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                        raise RuntimeError('Benchmark wrote unsaved changes to disk')
                values = {'variant': label, 'run': run + 1, **{key: statistics.median(result[key]) for key in ['expansion_ms', 'expansion_dispatch_ms', 'typing_ms', 'typing_dispatch_ms']}}
                summary.append(values)
                print(json.dumps(values), flush=True)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
