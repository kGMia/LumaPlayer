#!/usr/bin/env python3
"""Short real-video holdout comparison. Does not modify input or player defaults."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--pairs', type=int, default=8)
    parser.add_argument('--start', type=float, default=0)
    parser.add_argument('--tier', choices=['fast','balanced','hq'], default='fast')
    parser.add_argument('--target-fps', choices=[48,60], type=int, default=48)
    parser.add_argument('--reverse', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binary = ROOT/'native/RIFEBackend/.build/release/iive-rife'
    lite = ROOT/'build/models/rife-v4.25-lite.rmw'
    if not args.input.is_file() or not lite.is_file() or not binary.is_file():
        parser.error('Need an existing local input, converted Lite model and built native CLI')
    if not 1 <= args.pairs <= 120 or not (0 <= args.start < float('inf')):
        parser.error('Use 1–120 pairs and a finite, nonnegative start')
    args.output.mkdir(parents=True, exist_ok=False)
    # Record the exact selected file, not its private absolute path in shared reports.
    input_stamp = digest(args.input)
    candidates = [('v4.26', []), ('v4.25-lite', ['--model', str(lite)])]
    if args.reverse:
        candidates.reverse()
    runs = []
    for label, model in candidates:
        command = [str(binary), 'evaluate', str(args.input.resolve()), args.tier,
                   '--pairs', str(args.pairs), '--start', str(args.start),
                   '--target-fps', str(args.target_fps), *model]
        try:
            run = subprocess.run(command, capture_output=True, text=True, timeout=300)
            (args.output/f'{label}.stderr.log').write_text(run.stderr)
            if run.returncode:
                runs.append({'candidate':label, 'status':'failed', 'exit_code':run.returncode})
                continue
            result = json.loads(run.stdout)
            (args.output/f'{label}.json').write_text(json.dumps(result, indent=2)+'\n')
            runs.append({'candidate':label, 'status':'completed', 'result':result})
        except subprocess.TimeoutExpired as error:
            stderr = error.stderr or b''
            if isinstance(stderr, bytes):
                stderr = stderr.decode('utf-8', errors='replace')
            (args.output/f'{label}.stderr.log').write_text(stderr)
            runs.append({'candidate':label, 'status':'timeout'})
        except (OSError, ValueError) as error:
            runs.append({'candidate':label, 'status':'failed',
                         'error_type':type(error).__name__})
    # Never silently compare a file that changed between candidate runs.
    unchanged = digest(args.input) == input_stamp
    complete = unchanged and all(r['status']=='completed' for r in runs)
    matched = False
    if complete:
        a,b = (r['result'] for r in runs)
        def points(result):
            return [(p['previous_pts'],p['reference_pts'],p['next_pts'])
                    for p in result['quality']['per_pair']]
        matched = (points(a)==points(b) and
                   a['performance']['source_pairs']==b['performance']['source_pairs'] and
                   a['performance']['generated_frames']==b['performance']['generated_frames'] and
                   all(a[k]==b[k] for k in ('width','height','source_fps','target_fps','tier','pixel_format')))
    report = {'input_sha256':input_stamp,'input_unchanged':unchanged,
              'paired_comparison_valid':complete and matched,'player_realtime':None,
              'runs':runs,'note':'Held-out source frames test half-rate reconstruction. Adjacent-frame timing is a separate BGRA inference pass, not mpv/NV12 or display latency. No automatic model recommendation; inspect motion/cuts and repeat in reverse order.'}
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(args.output/'report.json')
    if not report['paired_comparison_valid']:
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
