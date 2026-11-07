#!/usr/bin/env python3
"""Isolated-process model comparison; never changes player settings or claims display FPS."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--width', type=int, default=1920)
    parser.add_argument('--height', type=int, default=1080)
    parser.add_argument('--pairs', type=int, default=20)
    parser.add_argument('--tier', choices=['fast','balanced','hq'], default='fast')
    parser.add_argument('--source-fps', choices=[24,30], type=int, default=24)
    parser.add_argument('--target-fps', choices=[48,60], type=int, default=48)
    parser.add_argument('--format', choices=['nv12','bgra'], default='nv12')
    parser.add_argument('--reverse', action='store_true', help='Swap run order to check thermal/order bias')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Choose a new output path; refusing overwrite')
    lite = ROOT/'build/models/rife-v4.25-lite.rmw'
    binary = ROOT/'native/RIFEBackend/.build/release/iive-rife'
    if not lite.is_file() or not binary.is_file():
        parser.error('First run scripts/prepare-rife-lite.py and scripts/build-native.sh')
    candidates = [('bundled-v4.26', []), ('v4.25-lite', ['--model', str(lite)])]
    if args.reverse:
        candidates.reverse()
    results = []
    for label, model in candidates:
        command = [str(binary), 'bench', str(args.width), str(args.height), args.tier, str(args.pairs),
                   '--source-fps', str(args.source_fps), '--target-fps', str(args.target_fps),
                   '--format', args.format, *model]
        run = subprocess.run(command, capture_output=True, text=True, timeout=300)
        if run.returncode:
            results.append({'candidate':label, 'status':'failed', 'error':run.stderr[-4000:]})
            continue
        results.append({'candidate':label, 'status':'completed', 'measurement':json.loads(run.stdout)})
    report = {'scope':'synthetic model stream; excludes decode, audio and presentation',
              'quality_assessed':False,'player_realtime':None,
              'note':'Repeat with --reverse. Compare equal tier/format/FPS; model padding differs. Do not infer player FPS from inference throughput.',
              'runs':results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as f:
        json.dump(report, f, indent=2);f.write('\n')
    print(args.output)
    if any(r['status']!='completed' for r in results):
        raise SystemExit(1)

if __name__ == '__main__':
    main()
