#!/usr/bin/env python3
"""Run the audit assertions against the app's real portable module graph.

Exit 1 is expected on audit baseline 716dfdb: four behavioral assertions fail.
No production files or the user's Git repository state are changed.
"""
from pathlib import Path
import shlex
import subprocess
import sys

here = Path(__file__).resolve().parent
repo = here.parents[3]
build = subprocess.run(
    [str(repo / "tools/zig"), "build", "test-app",
     "-Dtest-filter=audit_git_harness_template", "--verbose"],
    cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
)
if build.returncode:
    print(build.stdout)
    sys.exit(build.returncode)
line = next(line for line in build.stdout.splitlines()
            if "zig test " in line and "-Mroot=apps/zircon/tests/all.zig" in line)
args = shlex.split(line.removeprefix("info(verbose): "))
args[args.index("-Mroot=apps/zircon/tests/all.zig")] = "-Mroot=" + str(here / "app-repros.zig")
args.remove("--listen=-")
at = args.index("--test-filter")
del args[at:at + 2]
args[args.index("--name") + 1] = "audit-git-app-repros"
print(shlex.join(args), flush=True)
sys.exit(subprocess.run(args, cwd=repo).returncode)
