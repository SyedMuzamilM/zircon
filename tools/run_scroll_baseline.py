#!/usr/bin/env python3
"""Measure native scroll submission in disposable editor, Git and search fixtures."""
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
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--long-lines', action='store_true')
    parser.add_argument('--driver', type=Path, default=REPO / 'zig-out/bin/zircon-scroll-bench')
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    args.output.mkdir(parents=True, exist_ok=False)
    driver = args.driver.resolve()
    environment = {'platform': platform.platform(), 'machine': platform.machine(), 'driver_sha256': hashlib.sha256(driver.read_bytes()).hexdigest(), 'runs': args.runs, 'source_hashes': {p: hashlib.sha256((REPO / p).read_bytes()).hexdigest() for p in ['tools/bench_scroll.zig', 'packages/zircon_editor/src/canvas.zig', 'apps/zircon/src/search_editing.zig', 'packages/zircon_git_ui/src/review.zig']}}
    (args.output / 'environment.json').write_text(json.dumps(environment, indent=2))
    cases = [('editor', 'wrap'), ('git', 'wrap')] if args.long_lines else [('editor', 'plain'), ('editor', 'wrap'), ('git', 'plain'), ('git', 'wrap'), ('search', 'plain')]
    summary = []
    with tempfile.TemporaryDirectory(prefix='zircon-scroll-') as directory:
        root = Path(directory)
        data = ''.join(f'const value_{i} = {i}; // '+('needle' if i % 12 == 0 else 'context')+' The quick brown fox jumps over the lazy dog. 日本語\n' for i in range(12000))
        if args.long_lines:
            data = data.replace('The quick brown fox jumps over the lazy dog.', 'The quick brown fox jumps over the lazy dog. ' * 4)
        (root / 'main.zig').write_text(data)
        for command in [('init', '-qb', 'main'), ('config', 'user.name', 'Scroll fixture'), ('config', 'user.email', 'fixture@example.invalid'), ('add', 'main.zig'), ('-c', 'commit.gpgsign=false', 'commit', '-qm', 'Initial')]:
            subprocess.run(['git', '-C', directory, *command], check=True, capture_output=True)
        (root / 'main.zig').write_text(''.join(line.replace(' = ', ' = 1 + ') if 'needle' in line else line for line in data.splitlines(keepends=True)))
        expected = hashlib.sha256((root / 'main.zig').read_bytes()).hexdigest()
        for run in range(args.runs):
            for mode, wrap in cases[run % len(cases):] + cases[:run % len(cases)]:
                output = args.output.resolve() / f'{mode}-{wrap}-{run + 1}.json'
                subprocess.run([str(driver), directory, mode, wrap, str(output)], check=True, timeout=120)
                result = json.loads(output.read_text())
                samples = sorted(result['scroll_to_submit_ms'])
                summary.append({'mode': mode, 'wrap': wrap, 'run': run + 1, 'median_ms': statistics.median(samples), 'p95_ms': samples[int((len(samples)-1)*.95)], 'max_ms': max(samples), 'dispatch_median_ms': statistics.median(result['dispatch_ms']), 'max_nodes': max(result['nodes']), **{k: statistics.median(x[k] for x in result['phases']) for k in result['phases'][0]}})
                if hashlib.sha256((root / 'main.zig').read_bytes()).hexdigest() != expected:
                    raise RuntimeError('Scroll changed fixture bytes')
                print(summary[-1], flush=True)
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))

if __name__ == '__main__':
    main()
