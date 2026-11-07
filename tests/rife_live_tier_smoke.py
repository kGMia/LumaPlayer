#!/usr/bin/env python3
"""One short no-window live tier command check. Not a throughput benchmark."""
import importlib.util
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--duration", type=int, default=1, choices=range(1, 6))
parser.add_argument("--output-log", type=Path, default=root / "benchmarks/results/live-tier-smoke-20261017.log")
parser.add_argument("--require-source-transition", action="store_true")
args = parser.parse_args()
spec = importlib.util.spec_from_file_location("profile_tools", root / "benchmarks/pipeline_profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
clip = root / "build/checks/live-tier-smoke.mkv"
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
    f"testsrc2=size=256x128:rate=24:duration={args.duration}", "-c:v", "ffv1", "-pix_fmt", "yuv420p",
    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
    "-color_range", "tv", "-y", str(clip)], check=True, timeout=20)
log_path = args.output_log
with tempfile.TemporaryDirectory(prefix="iive-tier-", dir="/tmp") as temp, log_path.open("w") as log:
    ipc = str(Path(temp) / "mpv.sock")
    env = dict(os.environ)
    env.pop("IIVE_PROFILE_PREFETCH", None)
    child = subprocess.Popen([str(root / "build/mpv/mpv"), "--no-config", "--vo=null", "--ao=null",
        "--hwdec=no", "--idle=yes", "--keep-open=yes", "--input-terminal=no", "--msg-level=all=v",
        f"--input-ipc-server={ipc}", "--vf=@iive-rife:iive-rife=fps=60:tier=balanced:fallback=no",
        str(clip)], stdout=log, stderr=log, env=env)
    try:
        deadline = time.monotonic() + 60
        switched = False
        before = after = None
        preparing_emitted = []
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError("mpv exited before inspection")
            if Path(ipc).exists():
                meta = profile.get(ipc, "vf-metadata/iive-rife")
                if isinstance(meta, dict):
                    if not switched and int(meta.get("emitted", 0)) >= 4:
                        before = meta
                        assert profile.command(["vf-command", "iive-rife", "tier", "fast"], ipc)["error"] == "success"
                        switched = True
                    after = meta
                    if meta.get("state") == "switching-source":
                        preparing_emitted.append(int(meta["emitted"]))
                if profile.get(ipc, "eof-reached"):
                    break
            time.sleep(.02)
        else:
            raise TimeoutError("live tier EOF timeout")
        assert switched and after and after["requested_tier"] == "fast"
        assert after["generation"] == before["generation"], "tier switch unexpectedly reset timeline"
        assert int(after["tier_switches"]) == 1 and after["fallback"] == "no"
        profile.command(["quit"], ipc)
        assert child.wait(timeout=10) == 0
    finally:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
text = log_path.read_text()
frames = re.findall(r"\[iive-rife\] output pts=([\d.]+) synthesized=(\d)", text)
assert len(frames) == 60 * args.duration, len(frames)
assert any(s == "1" for _, s in frames)
assert all(abs(float(pts) - i / 60) < 1e-8 for i, (pts, _) in enumerate(frames))
if args.require_source_transition:
    assert preparing_emitted and max(preparing_emitted) > int(before["emitted"]), "no observed output during preparation"
print(json.dumps({"result": "PASS", "output_frames": len(frames), "tier_switches": after["tier_switches"],
                  "switch_ms": after["tier_switch_ms"], "generation_unchanged": True,
                  "preparation_output_observed": bool(preparing_emitted and max(preparing_emitted) > int(before["emitted"])),
                  "note": "synthetic small input; verifies ordering/command/EOF, not GUI smoothness"}))
