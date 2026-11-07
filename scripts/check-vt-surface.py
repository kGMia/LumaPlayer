#!/usr/bin/env python3
"""Link a no-window regression against the existing pinned mpv build objects.

Run scripts/build-mpv.sh (or build the Xcode project) first. No dependency fetch,
GUI, decoder session, or inference is started by this check.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / "build/mpv"
output = root / "build/checks/vt-surface-smoke"
output.parent.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
commands = json.loads((build / "compile_commands.json").read_text())
entry = next(c for c in commands if c["file"].endswith("/iive_surface.c"))
args = shlex.split(entry["command"])
for flag in ("-o", "-MF", "-MQ"):
    i = args.index(flag)
    del args[i:i + 2]
args.remove("-MD")
args[args.index("-c") + 1] = str(root / "tests/vt_surface_smoke.c")
args += ["-o", str(output) + ".o"]
subprocess.run(args, cwd=build, env=env, check=True)

link = shlex.split(subprocess.check_output(
    ["ninja", "-t", "commands", "libmpv.2.dylib"], cwd=build, text=True).splitlines()[-1])
link[link.index("-o") + 1] = str(output)
link = [a for a in link if a not in ("-shared", "-Wl,-undefined,dynamic_lookup")
        and not a.startswith("-Wl,-install_name,")]
link += [str(output) + ".o", "-framework", "OpenGL", "-framework", "IOSurface"]
subprocess.run(link, cwd=build, env=env, check=True)
subprocess.run([str(output)], cwd=root, env=env, check=True)
