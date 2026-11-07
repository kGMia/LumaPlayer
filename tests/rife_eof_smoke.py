#!/usr/bin/env python3
"""Tiny headless regression: a long source hold must not consume EOF's slot."""
import pathlib
import re
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
checks = root / 'build/checks'
checks.mkdir(parents=True, exist_ok=True)
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
clips = []
for fps in (8, 6):
    clip = checks / f'rife-eof-{fps}.mkv'
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
        '-i', f'testsrc2=size=64x64:rate={fps}', '-frames:v', '2', '-c:v', 'ffv1',
        '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709', '-color_trc', 'bt709',
        '-colorspace', 'bt709', '-color_range', 'tv', '-y', str(clip)], check=True, timeout=15)
    clips.append(clip)

# The second clip also verifies playlist auto-advance receives the first EOF.
log_path = root / 'benchmarks/results/rife-eof-after-20261026.log'
with log_path.open('w') as log:
    result = subprocess.run([str(root / 'build/mpv/mpv'), '--no-config', '--vo=null',
        '--ao=null', '--hwdec=no', '--untimed', '--msg-level=all=v',
        '--vf=iive-rife=fps=60:tier=fast:fallback=no', *map(str, clips)],
        stdout=log, stderr=subprocess.STDOUT, timeout=15)
text = log_path.read_text()
assert result.returncode == 0 and 'End of file' in text, f'exit={result.returncode}; see {log_path}'
assert 'RIFE failure:' not in text, 'A valid long tail must not become an output-capacity failure'
frames = re.findall(r'\[iive-rife\] output pts=([\d.]+) synthesized=(\d)', text)
assert len(frames) == 4, frames
for pair, fps in zip((frames[:2], frames[2:]), (8, 6)):
    assert abs(float(pair[0][0])) < 1e-6
    assert abs(float(pair[1][0])-1/fps) < .0011
    assert all(synth == '0' for _, synth in pair), 'Source holds must not claim AI output'
assert text.count('RIFE totals: emitted=2 synthesized=0') == 2
print('PASS: exact-capacity and oversized tails, 4 source frames, playlist advance and final EOF; no window')
