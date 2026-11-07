#!/usr/bin/env python3
"""One 0.5-second, no-window RIFE -> FSRCNNX ordering/EOF check. Not a benchmark."""
import pathlib
import argparse
import re
import shutil
import subprocess
import math

root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--log', type=pathlib.Path,
                    default=root / 'benchmarks/results/phase5-prefetch-20261016.log')
parser.add_argument('--check-reuse', action='store_true',
                    help='Play the clip twice and check exclusive compiled-program reuse')
args = parser.parse_args()
check = root / 'build/checks'
check.mkdir(parents=True, exist_ok=True)
clip = check / 'prefetch-smoke.mkv'
log_path = args.log
log_path.parent.mkdir(parents=True, exist_ok=True)
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
    'testsrc2=size=256x128:rate=24:duration=0.5', '-c:v', 'ffv1', '-pix_fmt', 'yuv420p',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
    '-color_range', 'tv', '-y', str(clip)], check=True, timeout=20)
with log_path.open('w') as log:
    result = subprocess.run([str(root / 'build/mpv/mpv'), '--no-config', '--vo=null',
        '--ao=null', '--hwdec=no', '--untimed', '--msg-level=all=v',
        '--vf=@iive-rife:iive-rife=fps=60:tier=fast:fallback=no,iive-fsrcnnx=tier=fast:fallback=no',
        '--term-playing-msg=IIVE_PREPARATION ' + ' '.join(
            '${vf-metadata/iive-rife/' + key + '}' for key in
            ('initializations', 'initialization_ms', 'prepare_weights_ms', 'prepare_context_ms',
             'prepare_pool_ms', 'prepare_compile_ms', 'prepare_probe_ms', 'compilation_cache_hit')),
        *([str(clip)] * (2 if args.check_reuse else 1))],
        stdout=log, stderr=subprocess.STDOUT, timeout=60)
text = log_path.read_text()
rife = re.findall(r'\[iive-rife\] output pts=([\d.]+) synthesized=(\d)', text)
sr = re.findall(r'\[iive-apple\] output pts=([\d.]+) synthesized=(\d)', text)
assert result.returncode == 0 and 'End of file' in text
assert any(s == '1' for _, s in rife), 'No synthesized frames; bypass is not a pass'
plays = 2 if args.check_reuse else 1
assert len(rife) == len(sr) == 30 * plays
for frames in (rife, sr):
    for start in range(0, len(frames), 30):
        pts = [float(p) for p, _ in frames[start:start + 30]]
        assert all(b > a for a, b in zip(pts, pts[1:])), 'Non-monotonic PTS'
        if frames is rife:
            assert any(s == '1' for _, s in frames[start:start + 30]), 'No synthesis in this playback'
assert [p for p, _ in rife] == [p for p, _ in sr]
assert '512x256 nv12' in text, 'SR size not confirmed'
preparations = re.findall(r'^IIVE_PREPARATION (.+)$', text, re.MULTILINE)
assert len(preparations) == plays, 'Missing preparation metadata'
for preparation in preparations:
    fields = preparation.split()
    timing = [float(value) for value in fields[:-1]]
    assert len(timing) == 7 and timing[0] == 1
    assert all(math.isfinite(value) and value >= 0 for value in timing)
    # Named subphases are inside initialization, not extra time to add to its total.
    assert sum(timing[2:]) <= timing[1] + .02, 'Preparation phases exceed total'
    assert fields[-1] in ('yes', 'no')
if args.check_reuse:
    assert preparations[0].split()[-1] == 'no', 'First playback should compile'
    assert preparations[1].split()[-1] == 'yes', 'Second playback did not reuse compilation'
    assert float(preparations[1].split()[5]) == 0, 'Cache hit should skip compilation'
    print('PASS: second playback reused compilation; timings: ' + ' / '.join(preparations))
print(f'PASS: {len(sr)} ordered frames; RIFE synthesized {sum(s == "1" for _, s in rife)}; 512x256 SR; clean EOF')
print('PASS: initialization metadata includes five finite subphases')
