#!/usr/bin/env python3
"""One entry point for existing build, focused check and signed packaging scripts."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILDS = {"player": "build-player-modern.sh", "native": "build-native.sh", "mpv": "build-mpv.sh"}
CHECKS = {"transport": "check-transport-feedback.sh", "frame-step": "check-frame-step.sh",
          "queue": "check-queue-metadata.sh", "remote": "check-remote-browser.sh"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing them")
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="Build a component; player also signs and packages")
    build.add_argument("target", choices=BUILDS)
    build.add_argument("--configuration", choices=("Debug", "Release"), default="Debug",
                       help="Player configuration; native/mpv use their existing release scripts")
    check = commands.add_parser("check", help="Run only explicitly selected focused checks; no GUI")
    check.add_argument("targets", choices=CHECKS, nargs="+")
    package = commands.add_parser("package", help="Package an existing signed player build")
    package.add_argument("--configuration", choices=("Debug", "Release"), default="Debug")
    package.add_argument("--source-app", type=Path)
    args = parser.parse_args()
    if args.command == "build":
        jobs = [["bash", str(ROOT / "scripts" / BUILDS[args.target])]]
        if args.target == "player": jobs[0].append(args.configuration)
    elif args.command == "check":
        jobs = [["bash", str(ROOT / "scripts" / CHECKS[target])] for target in dict.fromkeys(args.targets)]
    else:
        jobs = [[sys.executable, str(ROOT / "scripts/package-player.py"), args.configuration]]
        if args.source_app: jobs[0].extend(["--source-app", str(args.source_app.resolve())])
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    for job in jobs:
        print(shlex.join(job), flush=True)
        if not args.dry_run:
            result = subprocess.run(job, cwd=ROOT, env=environment)
            if result.returncode:
                return result.returncode if result.returncode > 0 else 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
