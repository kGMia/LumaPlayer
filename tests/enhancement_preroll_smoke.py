#!/usr/bin/env python3
"""Short headless seek check; counts actual jobs, not a playback benchmark."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--label', required=True)
parser.add_argument('--expect-bypass', action='store_true')
parser.add_argument('--disable-drop', action='store_true')
args = parser.parse_args()
assert re.fullmatch(r'[a-z0-9-]+', args.label)
checks = root / 'build/checks'
checks.mkdir(parents=True, exist_ok=True)
clip = checks / 'enhancement-preroll.mp4'
subprocess.run([shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg',
    '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
    'testsrc2=size=256x128:rate=30:duration=2', '-c:v', 'libx264',
    '-g', '60', '-bf', '0', '-sc_threshold', '0', '-pix_fmt', 'yuv420p',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
    '-color_range', 'tv', '-y', str(clip)], check=True, timeout=20)
log_path = root / f'benchmarks/results/enhancement-preroll-{args.label}.log'
with log_path.open('w') as log:
    result = subprocess.run([str(root / 'build/mpv/mpv'), '--no-config',
        '--vo=null', '--ao=null', '--hwdec=no', '--untimed', '--msg-level=all=v',
        '--hr-seek=always', '--hr-seek-framedrop=' + ('no' if args.disable_drop else 'yes'),
        '--start=1.3', '--length=.35',
        '--vf=iive-rife=fps=60:tier=fast:fallback=no,iive-fsrcnnx=tier=fast:fallback=no',
        str(clip)], env={**os.environ, 'IIVE_PROFILE': '1'},
        stdout=log, stderr=subprocess.STDOUT, timeout=30)
text = log_path.read_text()
assert result.returncode == 0 and 'End of file' in text, log_path
assert 'RIFE failure:' not in text
jobs = [json.loads(s) for s in re.findall(r'IIVE_PROFILE (\{[^\n]+\})', text)]
summary = {}
for stage in ('rife', 'sr'):
    early = [j for j in jobs if j.get('event') == 'job' and
             j.get('stage') == stage and j['pts'] < 1.3 - .105]
    assert early, f'No decoded preroll for {stage}; test would be inconclusive'
    skipped = [j for j in early if j['state'] == 'seek-preroll']
    summary[stage] = {'early_jobs': len(early), 'skipped': len(skipped),
        'early_model_calls': sum(j['model_call_ms'] > 0 for j in early)}
    if args.expect_bypass:
        assert len(skipped) == len(early) and all(j['model_call_ms'] == 0 for j in early)
    else:
        assert any(j['model_call_ms'] > 0 for j in early)
        assert not skipped
for tag in ('iive-rife', 'iive-apple'):
    frames = [(float(p), int(s)) for p, s in re.findall(
        rf'\[{tag}\] output pts=([\d.]+) synthesized=(\d)', text)]
    assert frames and all(b[0] > a[0] for a, b in zip(frames, frames[1:]))
    assert any(1.295 <= p <= 1.32 for p, _ in frames), 'Missing seek boundary frame'
    if tag == 'iive-rife':
        assert any(p >= 1.3 and s for p, s in frames), 'AI did not resume after seek'
assert '512x256 nv12' in text
log_path.with_suffix('.json').write_text(json.dumps(summary, indent=2) + '\n')
print('PASS:', summary, '; ordered seek boundary, AI resumed, SR size and EOF; no window')
